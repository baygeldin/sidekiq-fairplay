require "spec_helper"

class RegularJob
  include Sidekiq::Job

  def perform(foo)
  end
end

class FairplayJob
  include Sidekiq::Job
  include Sidekiq::Fairplay::Job

  def perform(tenant_key, foo)
  end
end

RSpec.describe Sidekiq::Fairplay do
  before do
    FairplayJob.sidekiq_fairplay_options \
      enqueue_interval:,
      enqueue_jobs:,
      planner_queue:,
      planner_lock_ttl:,
      latency_threshold:,
      tenant_key:,
      tenant_weights:
  end

  let(:enqueue_interval) { 1 }
  let(:enqueue_jobs) { 10 }
  let(:planner_queue) { "default" }
  let(:planner_lock_ttl) { 60 }
  let(:latency_threshold) { 60 }
  let(:tenant_key) { ->(tenant_key, *_args) { tenant_key } }
  let(:tenant_weights) { ->(tenant_keys) { tenant_keys.to_h { |tid| [tid, 1] } } }

  describe "fairness (probabilistic)" do
    # Seed Ruby's PRNG for deterministic results
    around do |example|
      prev = srand(1234)
      example.run
    ensure
      srand(prev)
    end

    let(:enqueue_jobs) { 1000 }
    let(:tenant_weights) do
      ->(tenant_ids) do
        mapping = {"t1" => 1, "t2" => 3, "t3" => 6}
        tenant_ids.to_h { |tid| [tid, mapping.fetch(tid, 1)] }
      end
    end

    it "enqueues approximately proportional to weights" do
      enqueue_jobs.times do |i|
        FairplayJob.perform_async("t1", "a#{i}")
        FairplayJob.perform_async("t2", "b#{i}")
        FairplayJob.perform_async("t3", "c#{i}")
      end

      Sidekiq::Fairplay::Planner.new.perform("FairplayJob")

      expect(FairplayJob).to have_enqueued_sidekiq_job.exactly(enqueue_jobs)

      jobs_per_tenant = FairplayJob.jobs.each_with_object(Hash.new(0)) do |job, memo|
        memo[job["args"].first] += 1
      end

      expected_jobs_per_tenant = {"t1" => 100, "t2" => 300, "t3" => 600}
      tolerance = 0.25 # 25% tolerance to avoid flakiness across Ruby versions

      expected_jobs_per_tenant.each do |tid, exp|
        low = (exp * (1 - tolerance)).floor
        high = (exp * (1 + tolerance)).ceil

        expect(jobs_per_tenant[tid]).to be_between(low, high).inclusive
      end
    end
  end

  describe "basic functionality" do
    it "intercepts fairplay jobs and enqueues them later" do
      FairplayJob.perform_async("t1", "a")
      FairplayJob.perform_async("t2", "b")
      FairplayJob.perform_async("t3", "c")

      expect(FairplayJob).not_to have_enqueued_sidekiq_job
      expect(Sidekiq::Fairplay::Planner)
        .to have_enqueued_sidekiq_job("FairplayJob")
        .exactly(1)
        .immediately

      Sidekiq::Fairplay::Planner.perform_one

      expect(FairplayJob).to have_enqueued_sidekiq_job.exactly(3)
      expect(FairplayJob).to have_enqueued_sidekiq_job("t1", "a")
      expect(FairplayJob).to have_enqueued_sidekiq_job("t2", "b")
      expect(FairplayJob).to have_enqueued_sidekiq_job("t3", "c")
    end

    context "with custom planner queue" do
      let(:planner_queue) { "whatever" }

      it "enqueues the planner job on the configured queue" do
        FairplayJob.perform_async("t1", "a")

        Sidekiq::Fairplay::Planner.perform_one

        expect(Sidekiq::Fairplay::Planner)
          .to have_enqueued_sidekiq_job("FairplayJob")
          .on(planner_queue)
          .in(enqueue_interval.to_i)

        expect(FairplayJob)
          .to have_enqueued_sidekiq_job("t1", "a")
          .on("default") # default queue for FairplayJob
      end
    end

    context "when latency threshold exceeded" do
      let(:queue) { instance_double(Sidekiq::Queue) }

      before do
        allow(Sidekiq::Queue).to receive(:new).and_return(queue)
        allow(queue).to receive(:latency).and_return(latency_threshold.to_i + 1)
      end

      it "reschedules the planner without enqueuing jobs" do
        FairplayJob.perform_async("t1", "a")

        Sidekiq::Fairplay::Planner.perform_one

        expect(FairplayJob).not_to have_enqueued_sidekiq_job
        expect(Sidekiq::Fairplay::Planner)
          .to have_enqueued_sidekiq_job("FairplayJob")
          .in(enqueue_interval.to_i)
      end
    end

    context "with custom weights" do
      let(:tenant_weights) do
        ->(tenant_ids) do
          tenant_ids.to_h do |tid|
            [tid, (tid == "t1") ? 1 : 0]
          end
        end
      end

      it "uses weights to prefer specific tenant" do
        FairplayJob.perform_async("t1", "a")
        FairplayJob.perform_async("t2", "b")

        Sidekiq::Fairplay::Planner.perform_one

        expect(FairplayJob).to have_enqueued_sidekiq_job.exactly(1)
        expect(FairplayJob).to have_enqueued_sidekiq_job("t1", "a")
        expect(FairplayJob).not_to have_enqueued_sidekiq_job("t2", "b")
      end
    end

    context "when too many jobs in the queue" do
      let(:enqueue_jobs) { 1 }

      it "respects the enqueue_jobs limit" do
        FairplayJob.perform_async("t1", "a")
        FairplayJob.perform_async("t1", "b")

        Sidekiq::Fairplay::Planner.perform_one

        expect(FairplayJob).to have_enqueued_sidekiq_job.exactly(1)
        expect(FairplayJob)
          .to have_enqueued_sidekiq_job("t1", "a")
          .or have_enqueued_sidekiq_job("t1", "b")
      end
    end
  end

  describe "edge cases" do
    it "ignores unknown job class" do
      Sidekiq::Fairplay::Planner.new.perform("UnknownJob")

      expect(Sidekiq::Fairplay::Planner).not_to have_enqueued_sidekiq_job
      expect(FairplayJob).not_to have_enqueued_sidekiq_job
    end

    it "has no effect on regular jobs" do
      RegularJob.perform_async("foo")

      expect(RegularJob).to have_enqueued_sidekiq_job("foo")
      expect(Sidekiq::Fairplay::Planner).not_to have_enqueued_sidekiq_job
    end

    it "has no effect on scheduled jobs" do
      FairplayJob.perform_in(5, "t1", "a")

      expect(FairplayJob).to have_enqueued_sidekiq_job("t1", "a").in(5)
      expect(Sidekiq::Fairplay::Planner).not_to have_enqueued_sidekiq_job
    end

    context "with zero weights for all tenants" do
      let(:tenant_weights) do
        ->(tenant_ids) { tenant_ids.to_h { |tid| [tid, 0] } }
      end

      it "enqueues no jobs" do
        FairplayJob.perform_async("t1", "a")
        FairplayJob.perform_async("t2", "b")

        Sidekiq::Fairplay::Planner.perform_one

        expect(FairplayJob).not_to have_enqueued_sidekiq_job
      end
    end
  end

  describe "errors" do
    let(:tenant_key) { ->(_tid, *_args) {} }

    it "raises when tenant key resolves to nil" do
      tenant_key

      expect { FairplayJob.perform_async("t1", "a") }
        .to raise_error(ArgumentError, /tenant key cannot be nil/)
    end
  end

  describe "implementation details" do
    it "reschedules planning for the next interval" do
      FairplayJob.perform_async("t1", "a")

      Sidekiq::Fairplay::Planner.perform_one

      expect(Sidekiq::Fairplay::Planner)
        .to have_enqueued_sidekiq_job("FairplayJob")
        .in(enqueue_interval.to_i)
    end

    context "when planner_lock_ttl is being held" do
      let(:planner_lock_ttl) { 42 }

      before do
        redis = Sidekiq::Fairplay::Redis.new
        redis.try_acquire_planner_lock(FairplayJob, "some_jid")
      end

      it "blocks planning until the TTL expires" do
        FairplayJob.perform_async("t1", "a")

        Sidekiq::Fairplay::Planner.perform_one

        expect(FairplayJob).not_to have_enqueued_sidekiq_job
        expect(Sidekiq::Fairplay::Planner)
          .to have_enqueued_sidekiq_job("FairplayJob")
          .in(enqueue_interval.to_i)
      end
    end

    context "when tenant_key and tenant_weights refer to class methods" do
      before do
        class << FairplayJob
          def static_tenant_key(tid, *_args) = tid
          def static_tenant_weights(tids) = tids.to_h { |tid| [tid, 1] }
        end
      end

      let(:tenant_key) { ->(tid, *args) { static_tenant_key(tid, *args) } }
      let(:tenant_weights) { ->(tids) { static_tenant_weights(tids) } }

      it "works as expected" do
        FairplayJob.perform_async("t1", "a")
        FairplayJob.perform_async("t2", "b")

        Sidekiq::Fairplay::Planner.perform_one

        expect(FairplayJob).to have_enqueued_sidekiq_job.exactly(2)
        expect(FairplayJob).to have_enqueued_sidekiq_job("t1", "a")
        expect(FairplayJob).to have_enqueued_sidekiq_job("t2", "b")
      end
    end

    context "when using ActiveSupport::Duration" do
      let(:enqueue_interval) { 1.minute }
      let(:latency_threshold) { 1.hour }
      let(:planner_lock_ttl) { 10.seconds }

      it "handles durations correctly" do
        FairplayJob.perform_async("t1", "a")

        Sidekiq::Fairplay::Planner.perform_one

        expect(Sidekiq::Fairplay::Planner)
          .to have_enqueued_sidekiq_job("FairplayJob")
          .in(enqueue_interval.to_i)

        expect(FairplayJob).to have_enqueued_sidekiq_job.exactly(1)
        expect(FairplayJob).to have_enqueued_sidekiq_job("t1", "a")
      end
    end
  end
end
