# Resources

> [!NOTE]
> Here you can find additional resources for my EuRuKo 2025 talk, *"Prioritization justice: lessons from making background jobs fair at scale"*. This document mainly covers three alternative approaches to fair prioritization: shuffle-sharding, interruptible iteration, and throttling.

## Shuffle-sharding

This is a powerful, highly scalable, and extremely simple strategy to implement. While it doesn't completely solve the problem of fairness, it can make unfairness dramatically less noticeable for most users—how effective it is depends on your tolerance for resource underutilization and your budget.

- ["Workload Isolation with Queue Sharding"](https://www.mikeperham.com/2019/12/17/workload-isolation-with-queue-sharding/) — a short and to the point blog post from Mike Perham explaining how to implement this strategy with Sidekiq.
- ["Workload Isolation Using Shuffle-Sharding"](https://d1.awsstatic.com/builderslibrary/pdfs/workload-isolation-using-shuffle-sharding.pdf) — an excellent article by Colm MacCárthaigh discussing the effectiveness of shuffle-sharding and how it was used to solve various issues at AWS.

## Interruptible iteration


This strategy is somewhat orthogonal to the problem of fairness. In fact, you’ll likely want to use it regardless of whatever fairness strategy you choose because long, monolithic background jobs are simply not a good practice—they are difficult to manage (e.g., if they fail, you lose all progress and must start over). Incidentally, interruptible iteration can also solve the fairness issue for you, if the main cause of it is such monolithic multi-step jobs hogging the queue.

- ["Sidekiq Iterable Jobs: With Great Power...."](https://judoscale.com/blog/sidekiq-iterable-jobs) — a great in-depth overview of this pattern from Judoscale, with practical recommendations on when to use it versus parallelizing your workload.
- [job-iteration](https://github.com/Shopify/job-iteration) — a popular gem from Shopify implementing this idea (Shopify was a pioneer in popularizing this pattern in the Ruby community).
- [Sidekiq Iteration](https://github.com/sidekiq/sidekiq/wiki/Iteration) — heavily inspired by the `job-iteration` gem, Sidekiq introduced this functionality in version 7.3.
- [Active Job Continuations](https://github.com/rails/rails/pull/55127) — recently introduced in Rails 8, Active Job Continuations finally allow us to easily split complex workflows into multiple steps.

## Throttling


The best way to think about this strategy is as an attempt to *approximate* fairness at the time of enqueueing by deprioritizing jobs from users suspected of being greedy. The downside is that you may accidentally penalize some users more than they deserve if your workload is bursty by nature (e.g., if users make 100% of their requests 10% of the time instead of *microdosing* by making 10% of requests 100% of the time—~which is scientifically more better btw~). On the bright side, this approach doesn’t suffer from underutilization, so if your workload is well distributed over time, it could be a good solution.

- ["Fair" multi-tenant prioritization of Sidekiq jobs—and our gem for it!](https://evilmartians.com/chronicles/fair-multi-tenant-prioritization-of-sidekiq-jobs-and-our-gem-for-it) — if you want to implement this strategy in Sidekiq, then look no further than this blog post from Andrey Novikov (or go straight to the [sidekiq-fair_tenant](https://github.com/Envek/sidekiq-fair_tenant) gem).
- ["The unreasonable effectiveness of leaky buckets (and how to make one)"](https://blog.julik.nl/2022/08/the-unreasonable-effectiveness-of-leaky-buckets) — since a large part of this strategy is deciding when to start deprioritizing jobs, leaky buckets turn out to be an extremely useful and efficient tool. This article by Julik Tarkhanov is probably the best one I've read on the subject.
- ["The Leaky Bucket rate limiter"](https://www.mikeperham.com/2020/11/09/the-leaky-bucket-rate-limiter/) — in this blog post, Mike Perham explains how the leaky bucket limiter is implemented in Sidekiq Enterprise.
- [Solid Queue's job priorities](https://github.com/rails/solid_queue#queue-order-and-priorities) and [GoodJob's job priorities](https://github.com/bensheldon/good_job#job-priority) — while not strictly related to this strategy, these are worth mentioning because individual job priorities (a unique feature of background processors backed by relational databases) can also be used to approximate fairness at the time of enqueueing.

## Misc
- [faqueue](https://github.com/palkan/faqueue) — practically academic research from Vladimir Dementyev comparing different fairness strategies (it includes two extra strategies, so check it out!).
- [fairway](https://github.com/customerio/fairway) — an honorary mention for the gem from Customer IO that, like `sidekiq-fairplay`, implements the approach using dynamic per-tenant queues. Unfortunately, the gem is long abandoned, likely because it heavily modifies Sidekiq internals (specifically the fetcher, a central part of the engine), making it difficult to maintain compatibility.
