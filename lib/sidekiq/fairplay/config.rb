module Sidekiq
  module Fairplay
    module Config
      include ActiveSupport::Configurable

      def self.options
        Sidekiq.default_configuration[:fairplay] || {}
      end

      config_accessor :default_latency_threshold do
        options[:default_latency_threshold] || 60 # seconds
      end

      config_accessor :default_planner_queue do
        options[:default_planner_queue] || "default"
      end

      config_accessor :default_planner_lock_ttl do
        options[:default_planner_lock_ttl] || 60 # seconds
      end

      # By default, all tenants have equal weight.
      config_accessor :default_tenant_weights do
        options[:default_tenant_weights] ||
          ->(tenant_ids) { tenant_ids.to_h { |tid| [tid, 1] } }
      end
    end
  end
end
