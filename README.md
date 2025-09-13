# sidekiq-fairplay

[![Build workflow](https://github.com/baygeldin/sidekiq-fairplay/actions/workflows/ci.yml/badge.svg)](https://github.com/baygeldin/sidekiq-fairplay/actions/workflows/ci.yml)
[![Gem Version](https://img.shields.io/gem/v/sidekiq-fairplay.svg)](https://rubygems.org/gems/sidekiq-fairplay)
[![Code Coverage](https://qlty.sh/gh/baygeldin/projects/sidekiq-fairplay/coverage.svg)](https://qlty.sh/gh/baygeldin/projects/sidekiq-fairplay)
[![Maintainability](https://qlty.sh/gh/baygeldin/projects/sidekiq-fairplay/maintainability.svg)](https://qlty.sh/gh/baygeldin/projects/sidekiq-fairplay)

> [!NOTE]
> This gem is a reference implementation of the approach I describe in my EuRuKo 2025 talk *“Prioritization justice: lessons from making background jobs fair at scale”*.
> While the approach itself is battle-tested in production in a real multi-tenant app with lots of users, the gem is not (yet). So, use at your own peril 🫣

Are you treating your users fairly? They could be stuck in the queue while a greedy user monopolizes your workers—and you might not even know it! This gem implements fair background job prioritization for Sidekiq: instead of letting a single noisy tenant hog your queues, `sidekiq‑fairplay` enqueues jobs in balanced rounds, using dynamically calculated tenant weights. It works especially well in multi‑tenant apps, where you want *fairness* even when some tenants are "needier" than others.

Take a look at the most basic example below: it intercepts all jobs you try to enqueue (e.g., via `HeavyJob.perform_async`) and slowly releases them into the main queue in batches of 100 jobs every minute, ensuring no tenant is forgotten.

```ruby
class HeavyJob
  include Sidekiq::Job
  include Sidekiq::Fairplay::Job

  sidekiq_fairplay_options(
    enqueue_interval: 1.minute,
    enqueue_jobs: 100,
    tenant_key: ->(user_id, _foo) { user_id }
  )

  def perform(user_id, foo)
    # do heavy work
  end
end
```

<a href="https://evilmartians.com/?utm_source=sidekiq-fair_tenant">
  <picture>
    <source
      media="(prefers-color-scheme: dark)"
      srcset="https://evilmartians.com/badges/sponsored-by-evil-martians_v2.0_for-dark-bg@2x.png"
    >
    <img
      src="https://evilmartians.com/badges/sponsored-by-evil-martians_v2.0@2x.png"
      alt="Sponsored by Evil Martians"
      width="236"
      height="54"
    >
  </picture>
</a>

## Requirements
- Ruby >= 3.4
- Sidekiq >= 7

## Installation

Add to your Gemfile and bundle:

```ruby
gem 'sidekiq-fairplay'
```

Configure the client middleware on both client and server:

```ruby
Sidekiq.configure_client do |config|
  config.client_middleware do |chain|
    chain.add Sidekiq::Fairplay::Middleware
  end
end

Sidekiq.configure_server do |config|
  config.client_middleware do |chain|
    chain.add Sidekiq::Fairplay::Middleware
  end
end
```

## API

In the following example you can see all of the available configuration parameters and their meaning:

```ruby
class HeavyJob
  include Sidekiq::Job
  include Sidekiq::Fairplay::Job

  sidekiq_options queue: :heavy_stuff

  sidekiq_fairplay_options(
    # How often the planner tries to enqueue more jobs into `heavy_stuff` (in seconds).
    # It should be large enough for the planner job to finish executing in that time.
    enqueue_interval: 60,

    # How many jobs the planner tries to enqueue every `enqueue_interval`.
    # If the jobs are processed faster than the planner enqueues them, increase this number.
    enqueue_jobs: 100,

    # Tenant ID extraction from the job arguments. It's required and it should return a string.
    # It is called in the client middleware (i.e. every time you call `SomeWorker.perform_async`).
    tenant_key: ->(tenant_id, *_args) { tenant_id },

    # Tenant weights extraction. It accepts a list of tenants who currently have jobs waiting to be enqueued.
    # It should return a hash with keys being tenant IDs and values being their respective weights/priorities.
    # It's called during the planning and it should be able to execute within `enqueue_interval`.
    tenant_weights: ->(tenant_ids) { tenant_ids.to_h { |tid| [tid, 1] } }

    # A *very* important parameter to control backpressure and avoid flooding the queue (in seconds).
    # If the latency of `heavy_stuff` is larger than this number, the planner will skip a beat.
    latency_threshold: 60,

    # The queue in which the planner job should be executing.
    planner_queue: 'default',

    # For how long should the planner job hold the lock (in seconds).
    # This is a protection against accidentally running multiple planners at the same time.
    planner_lock_ttl: 60,
  )

  def perform(tenant_id, foo)
    # do heavy work
  end
end
```

## Configuration
You can specify some of the default values in `sidekiq.yml`:

```yaml
fairplay:
  :default_latency_threshold: 60
  :default_planner_queue: default
  :default_planner_lock_ttl: 60
```

Or directly in the code:
```ruby
Sidekiq::Fairplay::Config.default_latency_threshold = 60
Sidekiq::Fairplay::Config.default_planner_queue = 'default'
Sidekiq::Fairplay::Config.default_planner_lock_ttl = 60
Sidekiq::Fairplay::Config.default_tenant_weights = ->(tenant_ids) { tenant_ids.to_h { |tid| [tid, 1] } }
```

## How it works

At a high level, `sidekiq-fairplay` introduces **virtual per-tenant queues**. Instead of enqueuing jobs directly into Sidekiq, each job first goes into its tenant's queue. Then, at regular intervals, a special planner job (`Sidekiq::Fairplay::Planner`) runs. The planner decides which jobs to promote from tenant queues into the main Sidekiq queue—while keeping things fair.

### Backpressure

Without backpressure, we’d just dump all jobs from tenant queues into the main queue and end up back at square one (high latency and unhappy users). To avoid that, the planner checks queue latency before enqueuing. If latency is already high, it waits. This ensures that **new tenants arriving later still get a chance** to have their jobs processed, even if older tenants are sitting on mountains of unprocessed work.

### Dynamic weights

We keep track of how many jobs are waiting to be enqueued for each tenant. Only tenants with pending work are passed to your `tenant_weights` callback, so your calculations can stay efficient. The callback returns weights: larger numbers mean more jobs get promoted to the main queue. So, weight `10` > weight `1` (just like [Sidekiq’s built-in queue weights](https://github.com/sidekiq/sidekiq/wiki/Advanced-Options#queues)).

From there, you can apply **your own prioritization logic**—for example:
- Favor paying customers over freeloaders.
- Cool down tenants who've just had a large batch processed.
- Balance "needy" vs. "quiet" tenants.

### Reliability

All operations—pushing jobs into tenant queues, pulling them out—are performed atomically in Redis using Lua scripts. This guarantees **consistent state** with a single round-trip. However, if a network failure or process crash happens after a job is enqueued into the main queue but before it’s dropped from its tenant queue, that job may be processed twice. In other words, `sidekiq-fairplay` provides **at-least-once delivery semantics**. 

### Concurrency

We use two simple Redis-backed distributed locks:

1. **Planner deduplication lock**
   - Ensures only one planner per job class is enqueued within `enqueue_interval`.
   - This is needed to avoid flooding Sidekiq with duplicate jobs.

2. **Planner execution lock**  
   - Ensures only one planner per job class runs at a time.
   - Not strictly necessary (the first lock already prevents most issues), but adds safety.  

⚠️ Note: If a planner takes longer than its `planner_lock_ttl`, multiple planners may run concurrently.  
It's not the end of the world, but it means you probably should **optimize your `tenant_weights` logic** and/or increase the `enqueue_interval`.

## Troubleshooting

If you use Sidekiq Pro and are using `reliable_scheduler!`, then keep in mind that it bypasses the client middlewares. This essentially means that all jobs scheduled via `perform_in/perform_at` will bypass the planner and go directly into the main queue.

## Development

After checking out the repo, run `bin/setup` to install dependencies. To execute the test suite simply run `rake`.

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/baygeldin/sidekiq-fairplay.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
