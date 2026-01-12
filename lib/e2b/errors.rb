# frozen_string_literal: true

module E2B
  # Base error class for all E2B SDK errors
  #
  # @attr_reader [Integer, nil] status_code HTTP status code if available
  # @attr_reader [Hash] headers Response headers if available
  class E2BError < StandardError
    attr_reader :status_code, :headers

    # Initialize a new E2BError
    #
    # @param message [String] Error message
    # @param status_code [Integer, nil] HTTP status code if available
    # @param headers [Hash] Response headers if available
    def initialize(message, status_code: nil, headers: {})
      @status_code = status_code
      @headers = headers || {}
      super(message)
    end
  end

  # Error raised when a requested resource is not found (HTTP 404)
  class NotFoundError < E2BError; end

  # Error raised when rate limit is exceeded (HTTP 429)
  class RateLimitError < E2BError; end

  # Error raised when an operation times out
  class TimeoutError < E2BError; end

  # Error raised when authentication fails (HTTP 401/403)
  class AuthenticationError < E2BError; end

  # Error raised when configuration is invalid
  class ConfigurationError < E2BError; end

  # Error raised when sandbox is not in expected state
  class SandboxStateError < E2BError; end

  # Error raised for conflict errors (HTTP 409)
  class ConflictError < E2BError; end
end
