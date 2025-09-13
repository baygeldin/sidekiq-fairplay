module Sidekiq
  module Fairplay
    class Redis
      LUA = {}
      SHAS = {}

      LUA[:push_tenant_job] = <<~LUA
        local queue_key = KEYS[1]
        local counts_key = KEYS[2]

        local tenant_id = ARGV[1]
        local job_payload = ARGV[2]

        redis.call('RPUSH', queue_key, job_payload)
        redis.call('HINCRBY', counts_key, tenant_id, 1)

        -- Clean up after a week of inactivity
        redis.call('EXPIRE', queue_key, 604800)
        redis.call('EXPIRE', counts_key, 604800)

        return 1
      LUA

      LUA[:pop_tenant_job] = <<~LUA
        local queue_key = KEYS[1]
        local counts_key = KEYS[2]

        local tenant_id = ARGV[1]

        local popped = redis.call('LPOP', queue_key)
        if not popped then
          return 0
        end

        local newcount = redis.call('HINCRBY', counts_key, tenant_id, -1)
        if newcount <= 0 then
          redis.call('HDEL', counts_key, tenant_id)
        end

        return 1
      LUA

      LUA[:release_planner_lock] = <<~LUA
        if redis.call('get', KEYS[1]) == ARGV[1] then
          redis.call('del', KEYS[1])
        end
      LUA

      def self.bootstrap_scripts
        Sidekiq.redis do |conn|
          LUA.each_with_object(SHAS) do |(name, lua), memo|
            memo[name] = conn.call("SCRIPT", "LOAD", lua)
          end
        end
      end

      def push_tenant_job(job_class, tenant_id, payload)
        script_call(
          :push_tenant_job,
          [tenant_queue_redis_key(job_class.name, tenant_id), tenant_counts_redis_key(job_class.name)],
          [tenant_id.to_s, payload.to_s]
        )
      end

      def pop_tenant_job(job_class, tenant_id)
        script_call(
          :pop_tenant_job,
          [tenant_queue_redis_key(job_class.name, tenant_id), tenant_counts_redis_key(job_class.name)],
          [tenant_id.to_s]
        )
      end

      def peek_tenant(job_class, tenant_id)
        redis_call(:lindex, tenant_queue_redis_key(job_class.name, tenant_id), 0)
      end

      def tenant_counts(job_class)
        redis_call(:hgetall, tenant_counts_redis_key(job_class.name)) || {}
      end

      def with_planner_lock(job_class, jid)
        return false unless try_acquire_planner_lock(job_class, jid)

        begin
          yield
        ensure
          release_planner_lock(job_class, jid)
        end

        true
      end

      def try_acquire_planner_lock(job_class, jid)
        key = execute_lock_redis_key(job_class.name)
        ttl = job_class.sidekiq_fairplay_options_hash[:planner_lock_ttl].to_i

        !!redis_call(:set, key, jid.to_s, nx: true, ex: ttl)
      end

      def release_planner_lock(job_class, jid)
        script_call(:release_planner_lock, [execute_lock_redis_key(job_class.name)], [jid.to_s])
      end

      def planner_enqueued_recently?(job_class)
        key = enqueue_lock_redis_key(job_class.name)
        window = job_class.sidekiq_fairplay_options_hash[:enqueue_interval].to_i

        redis_call(:set, key, "1", nx: true, ex: window) ? false : true
      end

      private

      def tenant_counts_redis_key(job_class_name)
        ns("#{job_class_name.underscore}:tenant_counts")
      end

      def tenant_queue_redis_key(job_class_name, tenant_id)
        ns("#{job_class_name.underscore}:tenant_queue:#{tenant_id}")
      end

      def enqueue_lock_redis_key(job_class_name)
        ns("#{job_class_name.underscore}:enqueue_lock")
      end

      def execute_lock_redis_key(job_class_name)
        ns("#{job_class_name.underscore}:execute_lock")
      end

      def ns(key)
        "fairplay:#{key}"
      end

      def redis_call(command, *args, **kwargs)
        Sidekiq.redis { |connection| connection.call(command.to_s.upcase, *args, **kwargs) }
      end

      def script_call(name, keys, args)
        self.class.bootstrap_scripts if SHAS.length != LUA.length

        redis_call(:evalsha, SHAS[name], keys.size, *keys, *args)
      rescue RedisClient::CommandError => e
        raise unless /NOSCRIPT/.match?(e.message)

        self.class.bootstrap_scripts
        retry
      end
    end
  end
end
