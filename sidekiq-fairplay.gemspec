lib = File.expand_path("lib", __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require "sidekiq/fairplay/version"

Gem::Specification.new do |spec|
  spec.name = "sidekiq-fairplay"
  spec.version = Sidekiq::Fairplay::VERSION
  spec.authors = ["Alexander Baygeldin"]
  spec.email = ["a.baygeldin@gmail.com"]
  spec.summary = <<~SUMMARY
    Make Sidekiq play fair — dynamic job prioritization for multi-tenant apps.
  SUMMARY
  spec.homepage = "http://github.com/baygeldin/sidekiq-fairplay"
  spec.license = "MIT"

  spec.files = Dir.glob("lib/**/*") + %w[README.md LICENSE]
  spec.require_paths = ["lib"]

  spec.required_ruby_version = ">= 3.4.0"

  spec.add_development_dependency "bundler", "~> 2.0"
  spec.add_development_dependency "pry", "~> 0.15"
  spec.add_development_dependency "rake", "~> 13.0"
  spec.add_development_dependency "rspec", "~> 3.0"
  spec.add_development_dependency "rspec-sidekiq", "~> 5.0"
  spec.add_development_dependency "standard", "~> 1.0"
  spec.add_development_dependency "standard-performance", "~> 1.0"
  spec.add_development_dependency "standard-rspec", "~> 0.3"
  spec.add_development_dependency "simplecov", "~> 0.22"
  spec.add_development_dependency "timecop", "~> 0.9"

  spec.add_dependency "activesupport", ">= 7.0"
  spec.add_runtime_dependency "sidekiq", ">= 7.0"

  spec.metadata["rubygems_mfa_required"] = "true"
end
