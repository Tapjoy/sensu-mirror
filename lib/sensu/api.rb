require File.join(File.dirname(__FILE__), 'base')
require File.join(File.dirname(__FILE__), 'redis')

gem 'thin', '1.5.0'
gem 'async_sinatra', '1.0.0'

require 'thin'
require 'sinatra/async'

module Sensu
  class API < Sinatra::Base
    register Sinatra::Async

    class << self
      def run(options={})
        EM::run do
          bootstrap(options)
          start
          trap_signals
        end
      end

      def bootstrap(options={})
        base = Base.new(options)
        $logger = base.logger
        $settings = base.settings
        base.setup_process
        if $settings[:api][:user] && $settings[:api][:password]
          use Rack::Auth::Basic do |user, password|
            user == $settings[:api][:user] && password == $settings[:api][:password]
          end
        end
      end

      def setup_redis
        $logger.debug('connecting to redis', {
          :settings => $settings[:redis]
        })
        $redis = Redis.connect($settings[:redis])
        $redis.on_error do |error|
          $logger.fatal('redis connection error', {
            :error => error.to_s
          })
          stop
        end
        $redis.before_reconnect do
          $logger.warn('reconnecting to redis')
        end
        $redis.after_reconnect do
          $logger.info('reconnected to redis')
        end
      end

      def setup_rabbitmq
        $logger.debug('connecting to rabbitmq', {
          :settings => $settings[:rabbitmq]
        })
        $rabbitmq = RabbitMQ.connect($settings[:rabbitmq])
        $rabbitmq.on_error do |error|
          $logger.fatal('rabbitmq connection error', {
            :error => error.to_s
          })
          stop
        end
        $rabbitmq.before_reconnect do
          $logger.warn('reconnecting to rabbitmq')
        end
        $rabbitmq.after_reconnect do
          $logger.info('reconnected to rabbitmq')
        end
        $amq = $rabbitmq.channel
      end

      def start
        setup_redis
        setup_rabbitmq
        Thin::Logging.silent = true
        Thin::Server.start(self, $settings[:api][:port])
      end

      def stop
        $logger.warn('stopping')
        $rabbitmq.close
        $redis.close
        $logger.warn('stopping reactor')
        EM::stop_event_loop
      end

      def trap_signals
        %w[INT TERM].each do |signal|
          Signal.trap(signal) do
            $logger.warn('received signal', {
              :signal => signal
            })
            stop
          end
        end
      end

      def test(options={})
        bootstrap(options)
        start
      end
    end

    configure do
      disable :protection
      disable :show_exceptions
    end

    not_found do
      ''
    end

    error do
      ''
    end

    helpers do
      def request_log_line
        $logger.info([env['REQUEST_METHOD'], env['REQUEST_PATH']].join(' '), {
          :remote_address => env['REMOTE_ADDR'],
          :user_agent => env['HTTP_USER_AGENT'],
          :request_method => env['REQUEST_METHOD'],
          :request_uri => env['REQUEST_URI'],
          :request_body => env['rack.input'].read
        })
        env['rack.input'].rewind
      end

      def health_filter
        unless $redis.connected?
          unless env['REQUEST_PATH'] == '/info'
            halt 500
          end
        end
      end

      def bad_request!
        status 400
        body ''
      end

      def not_found!
        status 404
        body ''
      end

      def created!
        status 201
        body ''
      end

      def accepted!
        status 202
        body ''
      end

      def no_content!
        status 204
        body ''
      end

      def event_hash(event_json, client_name, check_name)
        JSON.parse(event_json, :symbolize_names => true).merge(
          :client => client_name,
          :check => check_name
        )
      end

      def resolve_event(event)
        payload = {
          :client => event[:client],
          :check => {
            :name => event[:check],
            :output => 'Resolving on request of the API',
            :status => 0,
            :issued => Time.now.to_i,
            :handlers => event[:handlers],
            :force_resolve => true
          }
        }
        $logger.info('publishing check result', {
          :payload => payload
        })
        $amq.queue('results').publish(payload.to_json)
      end
    end

    before do
      content_type 'application/json'
      request_log_line
      health_filter
    end

    aget '/info' do
      response = {
        :sensu => {
          :version => VERSION
        },
        :rabbitmq => {
          :keepalives => {
            :messages => nil,
            :consumers => nil
          },
          :results => {
            :messages => nil,
            :consumers => nil
          }
        },
        :health => {
          :redis => $redis.connected? ? 'ok' : 'down',
          :rabbitmq => $rabbitmq.connected? ? 'ok' : 'down'
        }
      }
      if $rabbitmq.connected?
        $amq.queue('keepalives').status do |messages, consumers|
          response[:rabbitmq][:keepalives][:messages] = messages
          response[:rabbitmq][:keepalives][:consumers] = consumers
          $amq.queue('results').status do |messages, consumers|
            response[:rabbitmq][:results][:messages] = messages
            response[:rabbitmq][:results][:consumers] = consumers
            body response.to_json
          end
        end
      else
        body response.to_json
      end
    end

    aget '/clients' do
      response = Array.new
      $redis.smembers('clients') do |clients|
        unless clients.empty?
          clients.each_with_index do |client_name, index|
            client_key = "client:#{client_name}"
            $redis.get(client_key) do |client_json|
              begin
                response.push(JSON.parse(client_json.to_s))
              rescue JSON::ParserError => e
                $logger.warn("Unable to parse client JSON metadata '#{client_key}' : '#{client_json.inspect}' : #{e}")
              end
              if index == clients.size - 1
                body response.to_json
              end
            end
          end
        else
          body response.to_json
        end
      end
    end

    aget %r{/clients?/([\w\.-]+)$} do |client_name|
      $redis.get('client:' + client_name) do |client_json|
        unless client_json.nil?
          body client_json
        else
          not_found!
        end
      end
    end

    adelete %r{/clients?/([\w\.-]+)$} do |client_name|
      client_key = 'client:' + client_name
      $redis.get(client_key) do |client_json|
        $redis.hgetall('events:' + client_name) do |events|
          events.each do |check_name, event_json|
            resolve_event(event_hash(event_json, client_name, check_name))
          end
          EM::Timer.new(5) do
            begin
              client = JSON.parse(client_json.to_s, :symbolize_names => true)
              $logger.info('deleting client', {
                :client => client
              })
            rescue JSON::ParserError
              $logger.warn("Unable to parse client metadata #{client_key.inspect} : #{client_json.inspect}")
            end
            $redis.srem('clients', client_name)
            $redis.del('events:' + client_name)
            $redis.del('client:' + client_name)
            $redis.smembers('history:' + client_name) do |checks|
              checks.each do |check_name|
                $redis.del('history:' + client_name + ':' + check_name)
              end
              $redis.del('history:' + client_name)
            end
          end
          accepted!
        end
      end
    end

    aget '/checks' do
      body $settings.checks.to_json
    end

    aget %r{/checks?/([\w\.-]+)$} do |check_name|
      if $settings.check_exists?(check_name)
        response = $settings[:checks][check_name].merge(:name => check_name)
        body response.to_json
      else
        not_found!
      end
    end

    apost %r{/(?:check/)?request$} do
      begin
        post_body = JSON.parse(request.body.read, :symbolize_names => true)
        check_name = post_body[:check]
        subscribers = post_body[:subscribers] || Array.new
        if check_name.is_a?(String) && subscribers.is_a?(Array)
          if $settings.check_exists?(check_name)
            check = $settings[:checks][check_name]
            if subscribers.empty?
              subscribers = check[:subscribers] || Array.new
            end
            payload = {
              :name => check_name,
              :command => check[:command],
              :issued => Time.now.to_i
            }
            $logger.info('publishing check request', {
              :payload => payload,
              :subscribers => subscribers
            })
            subscribers.uniq.each do |exchange_name|
              $amq.fanout(exchange_name).publish(payload.to_json)
            end
            created!
          else
            not_found!
          end
        else
          bad_request!
        end
      rescue JSON::ParserError, TypeError
        bad_request!
      end
    end

    aget '/events' do
      response = Array.new
      $redis.smembers('clients') do |clients|
        unless clients.empty?
          clients.each_with_index do |client_name, index|
            $redis.hgetall('events:' + client_name) do |events|
              events.each do |check_name, event_json|
                response.push(event_hash(event_json, client_name, check_name))
              end
              if index == clients.size - 1
                body response.to_json
              end
            end
          end
        else
          body response.to_json
        end
      end
    end

    aget %r{/events/([\w\.-]+)$} do |client_name|
      response = Array.new
      $redis.hgetall('events:' + client_name) do |events|
        events.each do |check_name, event_json|
          response.push(event_hash(event_json, client_name, check_name))
        end
        body response.to_json
      end
    end

    aget %r{/events?/([\w\.-]+)/([\w\.-]+)$} do |client_name, check_name|
      $redis.hgetall('events:' + client_name) do |events|
        event_json = events[check_name]
        unless event_json.nil?
          body event_hash(event_json, client_name, check_name).to_json
        else
          not_found!
        end
      end
    end

    adelete %r{/events?/([\w\.-]+)/([\w\.-]+)$} do |client_name, check_name|
      $redis.hgetall('events:' + client_name) do |events|
        if events.include?(check_name)
          resolve_event(event_hash(events[check_name], client_name, check_name))
          accepted!
        else
          not_found!
        end
      end
    end

    apost %r{/(?:event/)?resolve$} do
      begin
        post_body = JSON.parse(request.body.read, :symbolize_names => true)
        client_name = post_body[:client]
        check_name = post_body[:check]
        if client_name.is_a?(String) && check_name.is_a?(String)
          $redis.hgetall('events:' + client_name) do |events|
            if events.include?(check_name)
              resolve_event(event_hash(events[check_name], client_name, check_name))
              accepted!
            else
              not_found!
            end
          end
        else
          bad_request!
        end
      rescue JSON::ParserError, TypeError
        bad_request!
      end
    end

    aget '/aggregates' do
      response = Array.new
      $redis.smembers('aggregates') do |checks|
        unless checks.empty?
          limit = 10
          if params[:limit]
            limit = params[:limit] =~ /^[0-9]+$/ ? params[:limit].to_i : nil
          end
          unless limit.nil?
            checks.each_with_index do |check_name, index|
              $redis.smembers('aggregates:' + check_name) do |aggregates|
                collection = {
                  :check => check_name,
                  :issued => aggregates.sort.reverse.take(limit)
                }
                response.push(collection)
                if index == checks.size - 1
                  body response.to_json
                end
              end
            end
          else
            bad_request!
          end
        else
          body response.to_json
        end
      end
    end

    aget %r{/aggregates/([\w\.-]+)$} do |check_name|
      $redis.smembers('aggregates:' + check_name) do |aggregates|
        unless aggregates.empty?
          limit = 10
          if params[:limit]
            limit = params[:limit] =~ /^[0-9]+$/ ? params[:limit].to_i : nil
          end
          unless limit.nil?
            body aggregates.sort.reverse.take(limit).to_json
          else
            bad_request!
          end
        else
          not_found!
        end
      end
    end

    adelete %r{/aggregates/([\w\.-]+)$} do |check_name|
      $redis.smembers('aggregates:' + check_name) do |aggregates|
        unless aggregates.empty?
          aggregates.each do |check_issued|
            result_set = check_name + ':' + check_issued
            $redis.del('aggregation:' + result_set)
            $redis.del('aggregate:' + result_set)
          end
          $redis.del('aggregates:' + check_name) do
            $redis.srem('aggregates', check_name) do
              no_content!
            end
          end
        else
          not_found!
        end
      end
    end

    aget %r{/aggregates?/([\w\.-]+)/([\w\.-]+)$} do |check_name, check_issued|
      result_set = check_name + ':' + check_issued
      $redis.hgetall('aggregate:' + result_set) do |aggregate|
        unless aggregate.empty?
          response = aggregate.inject(Hash.new) do |totals, (status, count)|
            totals[status] = Integer(count)
            totals
          end
          $redis.hgetall('aggregation:' + result_set) do |results|
            parsed_results = results.inject(Array.new) do |parsed, (client_name, check_json)|
              check = JSON.parse(check_json, :symbolize_names => true)
              parsed.push(check.merge(:client => client_name))
            end
            if params[:summarize]
              options = params[:summarize].split(',')
              if options.include?('output')
                outputs = Hash.new(0)
                parsed_results.each do |result|
                  outputs[result[:output]] += 1
                end
                response[:outputs] = outputs
              end
            end
            if params[:results]
              response[:results] = parsed_results
            end
            body response.to_json
          end
        else
          not_found!
        end
      end
    end

    apost %r{/stash(?:es)?/(.*)} do |path|
      begin
        post_body = JSON.parse(request.body.read)
        $redis.set('stash:' + path, post_body.to_json) do
          $redis.sadd('stashes', path) do
            created!
          end
        end
      rescue JSON::ParserError
        bad_request!
      end
    end

    aget %r{/stash(?:es)?/(.*)} do |path|
      $redis.get('stash:' + path) do |stash_json|
        unless stash_json.nil?
          body stash_json
        else
          not_found!
        end
      end
    end

    adelete %r{/stash(?:es)?/(.*)} do |path|
      $redis.exists('stash:' + path) do |stash_exists|
        if stash_exists
          $redis.srem('stashes', path) do
            $redis.del('stash:' + path) do
              no_content!
            end
          end
        else
          not_found!
        end
      end
    end

    aget '/stashes' do
      $redis.smembers('stashes') do |stashes|
        body stashes.to_json
      end
    end

    apost '/stashes' do
      begin
        post_body = JSON.parse(request.body.read)
        if post_body.is_a?(Array) && post_body.size > 0
          response = Hash.new
          post_body.each_with_index do |path, index|
            $redis.get('stash:' + path) do |stash_json|
              unless stash_json.nil?
                response[path] = JSON.parse(stash_json)
              end
              if index == post_body.size - 1
                body response.to_json
              end
            end
          end
        else
          bad_request!
        end
      rescue JSON::ParserError
        bad_request!
      end
    end
  end
end
