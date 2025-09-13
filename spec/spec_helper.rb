$LOAD_PATH << "." unless $LOAD_PATH.include?(".")

require "rubygems"
require "bundler/setup"
require "timecop"
require "simplecov"

require "sidekiq"
require "rspec-sidekiq"
require "sidekiq/fairplay"
require "pry"

SimpleCov.start do
  add_filter "spec"
end

Sidekiq::Fairplay.logger = nil

Sidekiq.configure_client do |config|
  config.redis = {db: 1}
  config.logger = nil

  config.client_middleware do |chain|
    chain.add Sidekiq::Fairplay::Middleware
  end
end

Sidekiq.configure_server do |config|
  config.redis = {db: 1}
  config.logger = nil

  config.client_middleware do |chain|
    chain.add Sidekiq::Fairplay::Middleware
  end
end

RSpec::Sidekiq.configure do |config|
  config.clear_all_enqueued_jobs = true
  config.warn_when_jobs_not_processed_by_sidekiq = false
end

RSpec.configure do |config|
  config.order = :random
  config.run_all_when_everything_filtered = true
  config.example_status_persistence_file_path = "spec/examples.txt"

  config.before do
    Sidekiq.redis do |conn|
      keys = conn.call("KEYS", "fairplay*")
      keys.each { |key| conn.call("DEL", key) }
    end
  end

  config.before do
    Timecop.freeze
  end

  config.after do
    Timecop.return
  end
end

$LOAD_PATH << File.join(File.dirname(__FILE__), "..", "lib")
