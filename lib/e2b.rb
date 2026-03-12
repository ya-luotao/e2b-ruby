# frozen_string_literal: true

# E2B Ruby SDK
# Ruby client for E2B sandbox API

# Core requires
require_relative "e2b/version"
require_relative "e2b/errors"
require_relative "e2b/configuration"

# API layer
require_relative "e2b/api/http_client"
require_relative "e2b/paginator"

# Models
require_relative "e2b/models/sandbox_info"
require_relative "e2b/models/snapshot_info"
require_relative "e2b/models/process_result"
require_relative "e2b/models/entry_info"

# Services
require_relative "e2b/services/base_service"
require_relative "e2b/services/command_handle"
require_relative "e2b/services/commands"
require_relative "e2b/services/filesystem"
require_relative "e2b/services/watch_handle"
require_relative "e2b/services/pty"
require_relative "e2b/services/git"

# Core classes
require_relative "e2b/sandbox"
require_relative "e2b/client"

# E2B SDK for Ruby
#
# Provides access to E2B sandboxes - secure cloud environments
# for AI-generated code execution.
#
# @example Quick start with Sandbox class (recommended)
#   sandbox = E2B::Sandbox.create(template: "base", api_key: "your-key")
#
#   result = sandbox.commands.run("echo 'Hello, World!'")
#   puts result.stdout
#
#   sandbox.files.write("/home/user/hello.txt", "Hello!")
#   content = sandbox.files.read("/home/user/hello.txt")
#
#   sandbox.kill
#
# @example Using Client class
#   client = E2B::Client.new(api_key: "your-api-key")
#   sandbox = client.create(template: "base")
#
# @example Using global configuration
#   E2B.configure do |config|
#     config.api_key = "your-api-key"
#   end
#
#   sandbox = E2B::Sandbox.create(template: "base")
#
# @see https://e2b.dev/docs E2B Documentation
module E2B
  ALL_TRAFFIC = "0.0.0.0/0"

  class << self
    # @return [Configuration, nil] Global configuration
    attr_accessor :configuration

    # Configure the E2B SDK globally
    #
    # @yield [config] Configuration block
    # @yieldparam config [Configuration] Configuration instance
    # @return [Configuration]
    #
    # @example
    #   E2B.configure do |config|
    #     config.api_key = "your-api-key"
    #     config.domain = "e2b.app"
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
