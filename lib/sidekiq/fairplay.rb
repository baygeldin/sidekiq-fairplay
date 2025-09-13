require "active_support"
require "active_support/inflector"
require "active_support/core_ext/string"
require "active_support/configurable"
require "active_support/core_ext/numeric/time"
require "sidekiq"
require "sidekiq/api"

require "sidekiq/fairplay/version"

module Sidekiq
  module Fairplay
    autoload :Config, "sidekiq/fairplay/config"
    autoload :Redis, "sidekiq/fairplay/redis"
    autoload :Middleware, "sidekiq/fairplay/middleware"
    autoload :Planner, "sidekiq/fairplay/planner"

    class << self
      attr_writer :logger

      def logger
        @logger ||= Sidekiq.logger
      end
    end
  end
end

module Sidekiq
  module Fairplay
    module Job
      def self.included(base)
        base.extend(ClassMethods)
      end

      module ClassMethods
        def sidekiq_fairplay_options(opts = {})
          opts = opts.compact

          unless opts.key?(:enqueue_jobs) && opts.key?(:enqueue_interval)
            raise ArgumentError, "You must specify how many jobs to enqueue and how often."
          end

          unless opts.key?(:tenant_key) && opts[:tenant_key].respond_to?(:call)
            raise ArgumentError, "You must provide the tenant_key lambda."
          end

          @sidekiq_fairplay_options = default_fairplay_options.merge(opts)
        end

        def sidekiq_fairplay_options_hash
          @sidekiq_fairplay_options || default_fairplay_options
        end

        private

        def default_fairplay_options
          {
            latency_threshold: Sidekiq::Fairplay::Config.default_latency_threshold,
            planner_queue: Sidekiq::Fairplay::Config.default_planner_queue,
            planner_lock_ttl: Sidekiq::Fairplay::Config.default_planner_lock_ttl,
            tenant_weights: Sidekiq::Fairplay::Config.default_tenant_weights
          }
        end
      end
    end
  end
end
