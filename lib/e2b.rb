# frozen_string_literal: true

# E2B Ruby SDK
# Unofficial Ruby client for E2B sandbox API

# Core requires
require_relative "e2b/version"
require_relative "e2b/errors"
require_relative "e2b/configuration"

# API layer
require_relative "e2b/api/http_client"

# Models
require_relative "e2b/models/sandbox_info"
require_relative "e2b/models/process_result"

# Services
require_relative "e2b/services/base_service"
require_relative "e2b/services/commands"
require_relative "e2b/services/filesystem"

# Core classes
require_relative "e2b/sandbox"
require_relative "e2b/client"

# E2B SDK for Ruby
#
# Unofficial Ruby SDK for interacting with E2B sandboxes - secure cloud environments
# for AI-generated code execution.
#
# @example Basic usage with API key
#   client = E2B::Client.new(api_key: "your-api-key")
#   sandbox = client.create(template: "base")
#
#   # Execute commands
#   result = sandbox.commands.run("echo 'Hello, World!'")
#   puts result.stdout
#
#   # Work with files
#   sandbox.files.write("/home/user/hello.txt", "Hello!")
#
#   # Clean up
#   sandbox.kill
#
# @example Using environment variables
#   # Set E2B_API_KEY in your environment
#   client = E2B::Client.new
#   sandbox = client.create(template: "my-template")
#
# @see https://e2b.dev/docs E2B Documentation
module E2B
  class << self
    # @return [Configuration, nil] Global configuration
    attr_accessor :configuration

    # Configure the E2B SDK globally
    #
    # @yield [config] Configuration block
    # @yieldparam config [Configuration] Configuration instance
    #
    # @example
    #   E2B.configure do |config|
    #     config.api_key = "your-api-key"
    #     config.timeout_ms = 300_000
    #   end
    def configure
      self.configuration ||= Configuration.new
      yield(configuration) if block_given?
      configuration
    end

    # Reset global configuration
    def reset_configuration!
      self.configuration = nil
    end
  end
end
