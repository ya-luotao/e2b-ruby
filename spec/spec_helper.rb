# frozen_string_literal: true

require "bundler/setup"

# Coverage is opt-in via COVERAGE=true so that single-file runs (which only
# exercise a slice of the gem) are not failed by the minimum-coverage gate.
# Must start before "e2b" is required so every file is tracked.
if ENV["COVERAGE"] == "true"
  require "simplecov"

  SimpleCov.start do
    enable_coverage :branch

    add_filter "/spec/"
    add_filter "/vendor/"

    add_group "Models", "lib/e2b/models"
    add_group "Services", "lib/e2b/services"
    add_group "API", "lib/e2b/api"

    # Floor below the measured baseline (≈82% line / ≈60% branch); raise it as
    # coverage improves rather than letting it drift down.
    minimum_coverage line: 80, branch: 58
  end
end

require "webmock/rspec"
require "e2b"

WebMock.disable_net_connect!(allow_localhost: true)

RSpec.configure do |config|
  config.disable_monkey_patching!
  config.expect_with :rspec do |expectations|
    expectations.syntax = :expect
  end

  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  config.order = :random
  Kernel.srand config.seed

  config.before do
    E2B.reset_configuration!
  end

  config.after do
    E2B.reset_configuration!
  end
end
