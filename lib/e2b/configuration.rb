# frozen_string_literal: true

module E2B
  # Configuration for E2B SDK
  #
  # @example
  #   config = E2B::Configuration.new(api_key: "your-api-key")
  #   config.timeout_ms = 600_000  # 10 minutes
  class Configuration
    # Default API base URL
    DEFAULT_API_URL = "https://api.e2b.app"

    # Default timeout in milliseconds (5 minutes)
    DEFAULT_TIMEOUT_MS = 300_000

    # Default sandbox timeout in milliseconds (1 hour)
    DEFAULT_SANDBOX_TIMEOUT_MS = 3_600_000

    # Maximum sandbox timeout (24 hours for Pro)
    MAX_SANDBOX_TIMEOUT_MS = 86_400_000

    # @return [String, nil] API key for authentication
    attr_accessor :api_key

    # @return [String] API base URL
    attr_accessor :api_url

    # @return [Integer] Request timeout in milliseconds
    attr_accessor :timeout_ms

    # @return [Integer] Default sandbox timeout in milliseconds
    attr_accessor :sandbox_timeout_ms

    # @return [String, nil] Default template ID
    attr_accessor :default_template

    # @return [Logger, nil] Optional logger
    attr_accessor :logger

    # Initialize configuration
    #
    # @param api_key [String, nil] API key (defaults to E2B_API_KEY env var)
    # @param api_url [String] API base URL
    # @param timeout_ms [Integer] Request timeout in milliseconds
    # @param sandbox_timeout_ms [Integer] Default sandbox timeout in milliseconds
    def initialize(
      api_key: nil,
      api_url: DEFAULT_API_URL,
      timeout_ms: DEFAULT_TIMEOUT_MS,
      sandbox_timeout_ms: DEFAULT_SANDBOX_TIMEOUT_MS
    )
      @api_key = api_key || ENV["E2B_API_KEY"]
      @api_url = api_url
      @timeout_ms = timeout_ms
      @sandbox_timeout_ms = sandbox_timeout_ms
      @default_template = nil
      @logger = nil
    end

    # Validate configuration
    #
    # @raise [ConfigurationError] If API key is missing
    def validate!
      raise ConfigurationError, "E2B API key is required. Set E2B_API_KEY environment variable or pass api_key option." if @api_key.nil? || @api_key.empty?
    end

    # Check if configuration is valid
    #
    # @return [Boolean]
    def valid?
      !@api_key.nil? && !@api_key.empty?
    end
  end
end
