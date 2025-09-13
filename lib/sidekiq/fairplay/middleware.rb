module Sidekiq
  module Fairplay
    class Middleware
      def call(job_class, job, _queue, _redis_pool)
        klass = job_class.is_a?(String) ? constantize(job_class) : job_class
        return nil unless klass

        opts = klass.respond_to?(:sidekiq_fairplay_options_hash) ? klass.sidekiq_fairplay_options_hash : {}
        args = job["args"] || []

        # For jobs scheduled via `perform_in` or `perform_at`, let it schedule as usual (including the planner job itself).
        # When the job is pushed onto the main queue from the scheduled set by Sidekiq, it will go through this middleware again.
        # NOTE: `reliable_scheduler` in Sidekiq Pro skips client middlewares, so such jobs will be enqueued bypassing the planner.
        return yield if job.key?("at")

        # Skip enqueuing the planner if it was already enqueued recently.
        if klass == Sidekiq::Fairplay::Planner
          target_job_class = constantize(args.first)
          return nil unless target_job_class
          return nil if redis.planner_enqueued_recently?(target_job_class)

          return yield
        end

        # Only apply fairplay logic to jobs that have it enabled.
        return yield unless klass.respond_to?(:sidekiq_fairplay_options_hash)

        # Perform the job as usual if it was enqueued by the planner.
        return yield if job["fairplay_enqueued_at"]

        tenant_id = klass.instance_exec(*args, &opts[:tenant_key])
        raise ArgumentError, "sidekiq-fairplay: tenant key cannot be nil" if tenant_id.nil?

        redis.push_tenant_job(klass, tenant_id, args.to_json)

        ::Sidekiq::Fairplay::Planner.set(queue: opts[:planner_queue]).perform_async(klass.name)

        nil # short-circuit job execution
      end

      private

      def constantize(name)
        name.constantize
      rescue NameError
        nil
      end

      def redis
        @redis ||= Sidekiq::Fairplay::Redis.new
      end
    end
  end
end
