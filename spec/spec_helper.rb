# frozen_string_literal: true

require "bundler/setup"
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
