# frozen_string_literal: true

module E2B
  # Base error class for all E2B SDK errors
  #
  # @attr_reader [Integer, nil] status_code HTTP status code if available
  # @attr_reader [Hash] headers Response headers if available
  class E2BError < StandardError
    attr_reader :status_code, :headers

    # @param message [String] Error message
    # @param status_code [Integer, nil] HTTP status code if available
    # @param headers [Hash] Response headers if available
    def initialize(message = nil, status_code: nil, headers: {})
      @status_code = status_code
      @headers = headers || {}
      super(message)
    end
  end

  # Alias matching official SDK naming
  SandboxError = E2BError

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

  # Error raised for invalid arguments
  class InvalidArgumentError < E2BError; end

  # Error raised when there is not enough disk space
  class NotEnoughSpaceError < E2BError; end

  # Error raised for template-related failures
  class TemplateError < E2BError; end

  # Error raised when a command exits with non-zero exit code
  #
  # @attr_reader [String] stdout Command stdout output
  # @attr_reader [String] stderr Command stderr output
  # @attr_reader [Integer] exit_code Process exit code
  # @attr_reader [String, nil] command_error Error message from the process
  class CommandExitError < E2BError
    attr_reader :stdout, :stderr, :exit_code, :command_error

    # @param stdout [String] Command stdout
    # @param stderr [String] Command stderr
    # @param exit_code [Integer] Process exit code
    # @param error [String, nil] Error message from the process
    def initialize(stdout: "", stderr: "", exit_code: 1, error: nil)
      @stdout = stdout
      @stderr = stderr
      @exit_code = exit_code
      @command_error = error
      message = "Command exited with code #{exit_code}"
      message += ": #{error}" if error
      message += "\nStderr: #{stderr}" if stderr && !stderr.empty?
      super(message)
    end

    def success?
      false
    end
  end

  # Error raised when git authentication fails
  class GitAuthError < AuthenticationError; end

  # Error raised when git upstream is missing
  class GitUpstreamError < E2BError; end
end
