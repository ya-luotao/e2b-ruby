# frozen_string_literal: true

module E2B
  # Configuration for E2B SDK
  #
  # Supports environment variables:
  #   - E2B_API_KEY: API key for authentication
  #   - E2B_ACCESS_TOKEN: Access token (alternative auth)
  #   - E2B_DOMAIN: Custom domain (default: e2b.app)
  #   - E2B_API_URL: Custom API URL
  #   - E2B_DEBUG: Enable debug logging
  #
  # @example
  #   E2B.configure do |config|
  #     config.api_key = "your-api-key"
  #     config.request_timeout = 120
  #   end
  class Configuration
    # Default domain
    DEFAULT_DOMAIN = "e2b.app"

    # Default API base URL
    DEFAULT_API_URL = "https://api.#{DEFAULT_DOMAIN}"

    # Default request timeout in seconds
    DEFAULT_REQUEST_TIMEOUT = 60

    # Default sandbox timeout in seconds
    DEFAULT_SANDBOX_TIMEOUT = 300

    # Default timeout in milliseconds (backward compat)
    DEFAULT_TIMEOUT_MS = 300_000

    # Default sandbox timeout in milliseconds (backward compat)
    DEFAULT_SANDBOX_TIMEOUT_MS = 300_000

    # Maximum sandbox timeout (24 hours for Pro)
    MAX_SANDBOX_TIMEOUT_MS = 86_400_000

    # @return [String, nil] API key for authentication
    attr_accessor :api_key

    # @return [String, nil] Access token (alternative auth method)
    attr_accessor :access_token

    # @return [String] E2B domain
    attr_accessor :domain

    # @return [String] API base URL
    attr_accessor :api_url

    # @return [Integer] Request timeout in seconds
    attr_accessor :request_timeout

    # @return [Integer] Request timeout in milliseconds (backward compat)
    attr_accessor :timeout_ms

    # @return [Integer] Default sandbox timeout in milliseconds (backward compat)
    attr_accessor :sandbox_timeout_ms

    # @return [Boolean] Enable debug logging
    attr_accessor :debug

    # @return [String, nil] Default template ID
    attr_accessor :default_template

    # @return [Logger, nil] Optional logger
    attr_accessor :logger

    # Initialize configuration
    #
    # @param api_key [String, nil] API key (defaults to E2B_API_KEY env var)
    # @param access_token [String, nil] Access token
    # @param domain [String] E2B domain
    # @param api_url [String] API base URL
    # @param request_timeout [Integer] Request timeout in seconds
    # @param timeout_ms [Integer] Request timeout in milliseconds (backward compat)
    # @param sandbox_timeout_ms [Integer] Default sandbox timeout in milliseconds
    # @param debug [Boolean] Enable debug logging
    def initialize(
      api_key: nil,
      access_token: nil,
      domain: nil,
      api_url: nil,
      request_timeout: DEFAULT_REQUEST_TIMEOUT,
      timeout_ms: DEFAULT_TIMEOUT_MS,
      sandbox_timeout_ms: DEFAULT_SANDBOX_TIMEOUT_MS,
      debug: false
    )
      @api_key = api_key || ENV["E2B_API_KEY"]
      @access_token = access_token || ENV["E2B_ACCESS_TOKEN"]
      @domain = domain || ENV["E2B_DOMAIN"] || DEFAULT_DOMAIN
      @debug = debug || ENV["E2B_DEBUG"]&.downcase == "true"
      @api_url = api_url || ENV["E2B_API_URL"] || self.class.default_api_url(@domain, debug: @debug)
      @request_timeout = request_timeout
      @timeout_ms = timeout_ms
      @sandbox_timeout_ms = sandbox_timeout_ms
      @default_template = nil
      @logger = nil
    end

    # Validate configuration
    #
    # @raise [ConfigurationError] If API key is missing
    def validate!
      if (@api_key.nil? || @api_key.empty?) && (@access_token.nil? || @access_token.empty?)
        raise ConfigurationError,
          "E2B API key is required. Set E2B_API_KEY environment variable or pass api_key option."
      end
    end

    # Check if configuration is valid
    #
    # @return [Boolean]
    def valid?
      (!@api_key.nil? && !@api_key.empty?) || (!@access_token.nil? && !@access_token.empty?)
    end

    def self.default_api_url(domain, debug: false)
      return "http://localhost:3000" if debug

      "https://api.#{domain}"
    end
  end
end
