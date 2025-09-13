require "json"
require "sidekiq/api"

module Sidekiq
  module Fairplay
    class Planner
      include Sidekiq::Job

      sidekiq_options retry: false

      def perform(job_class_name)
        @job_class = constantize(job_class_name)
        return unless job_class&.respond_to?(:sidekiq_fairplay_options_hash)

        planner = self.class.set(queue: options[:planner_queue])
        planner.perform_in(options[:enqueue_interval].to_i, job_class.name)

        return if job_queue.latency > options[:latency_threshold].to_i

        redis.with_planner_lock(job_class, Sidekiq::Context.current["jid"]) do
          enqueue_more_jobs!
        end
      end

      private

      attr_reader :job_class

      def enqueue_more_jobs!
        counts = fetch_tenant_counts
        return if counts.empty?

        weighted_tenant_ids = build_weighted_tenant_ids(counts.keys)
        return if weighted_tenant_ids.empty?

        pushed = 0

        while pushed < options[:enqueue_jobs]
          tid = weighted_tenant_ids.sample
          break unless tid && enqueue_job_for_tenant(tid)

          counts[tid] -= 1
          pushed += 1

          weighted_tenant_ids.reject! { it == tid } if counts[tid] <= 0
        end
      end

      def fetch_tenant_counts
        redis.tenant_counts(job_class)
          .transform_values { |c| c.to_i }
          .select { |_tid, c| c.positive? }
      end

      # Build a sampling bag with tenant IDs proportional to their weights.
      def build_weighted_tenant_ids(tenant_ids)
        weights = job_class.instance_exec(tenant_ids, &options[:tenant_weights])

        tenant_ids.each_with_object([]) do |tid, memo|
          weights[tid].to_i.times { memo << tid }
        end
      end

      def enqueue_job_for_tenant(tid)
        job_payload = redis.peek_tenant(job_class, tid)

        ok = Sidekiq::Client.push(
          "class" => job_class,
          "queue" => job_queue.name,
          "args" => JSON.parse(job_payload),
          "fairplay_enqueued_at" => Time.now.to_i
        )
        return false unless ok

        # Only remove the job from the tenant queue if it was successfully enqueued,
        # so that we don't lose a job if the process is killed or in case of a network issue.
        # However, this may lead to a job being processed more than once.
        redis.pop_tenant_job(job_class, tid)

        true
      end

      def constantize(name)
        name.constantize
      rescue NameError
        nil
      end

      def options
        @options ||= job_class.sidekiq_fairplay_options_hash
      end

      def job_queue
        @job_queue ||= Sidekiq::Queue.new(job_class.get_sidekiq_options["queue"] || "default")
      end

      def redis
        @redis ||= Sidekiq::Fairplay::Redis.new
      end
    end
  end
end
