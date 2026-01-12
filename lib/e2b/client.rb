# frozen_string_literal: true

module E2B
  # Main client for interacting with the E2B API
  #
  # This class provides methods to create, manage, and interact with E2B Sandboxes.
  #
  # @example Using environment variables
  #   # Set E2B_API_KEY in your environment
  #   client = E2B::Client.new
  #   sandbox = client.create(template: "base")
  #
  # @example Using explicit configuration
  #   client = E2B::Client.new(api_key: "your-api-key")
  #   sandbox = client.create(template: "my-custom-template")
  class Client
    # Default sandbox domain
    DEFAULT_DOMAIN = "e2b.app"

    # @return [Configuration] Client configuration
    attr_reader :config

    # Initialize a new E2B client
    #
    # @param config_or_options [Configuration, Hash, nil] Configuration object or options hash
    # @option config_or_options [String] :api_key API key for authentication
    # @option config_or_options [String] :api_url API URL (default: https://api.e2b.app)
    # @option config_or_options [Integer] :timeout_ms Request timeout in milliseconds
    # @option config_or_options [Integer] :sandbox_timeout_ms Default sandbox timeout
    #
    # @raise [ConfigurationError] If API key is not provided
    def initialize(config_or_options = nil)
      @config = resolve_config(config_or_options)
      @config.validate!

      @http_client = API::HttpClient.new(
        base_url: @config.api_url,
        api_key: @config.api_key,
        logger: @config.logger
      )

      @domain = DEFAULT_DOMAIN
    end

    # Create a new sandbox
    #
    # @param template [String] Template ID or alias
    # @param timeout_ms [Integer, nil] Sandbox timeout in milliseconds (default: 1 hour)
    # @param metadata [Hash, nil] Custom metadata key-value pairs
    # @param envs [Hash{String => String}, nil] Environment variables
    # @param auto_pause [Boolean] Whether to auto-pause when inactive
    # @param cpu_count [Integer, nil] Number of CPUs (default: 2)
    # @param memory_mb [Integer, nil] Memory in MB (default: 512, recommend 4096+ for Claude)
    # @param timeout [Integer] Request timeout in seconds
    #
    # @return [Sandbox] The created sandbox instance
    #
    # @example Create a basic sandbox
    #   sandbox = client.create(template: "base")
    #
    # @example Create with custom timeout and metadata
    #   sandbox = client.create(
    #     template: "my-template",
    #     timeout_ms: 7_200_000,  # 2 hours
    #     metadata: { "user" => "123", "purpose" => "testing" },
    #     envs: { "NODE_ENV" => "development" }
    #   )
    #
    # @example Create with more resources for Claude Code
    #   sandbox = client.create(
    #     template: "base",
    #     cpu_count: 4,
    #     memory_mb: 8192
    #   )
    def create(template:, timeout_ms: nil, metadata: nil, envs: nil, auto_pause: false, cpu_count: nil, memory_mb: nil, timeout: 120)
      timeout_ms ||= @config.sandbox_timeout_ms
      # E2B API expects timeout in seconds, not milliseconds
      timeout_seconds = (timeout_ms / 1000).to_i

      body = {
        templateID: template,
        timeout: timeout_seconds
      }
      body[:metadata] = metadata if metadata
      body[:envs] = envs if envs
      body[:autoPause] = auto_pause if auto_pause
      body[:cpuCount] = cpu_count if cpu_count
      body[:memoryMB] = memory_mb if memory_mb

      response = @http_client.post("/sandboxes", body: body, timeout: timeout)

      Sandbox.new(
        sandbox_data: response,
        http_client: @http_client,
        api_key: @config.api_key,
        domain: @domain
      )
    end

    # Connect to an existing sandbox
    #
    # @param sandbox_id [String] The sandbox ID
    # @param timeout_ms [Integer, nil] New timeout in milliseconds (extends TTL if provided)
    #
    # @return [Sandbox] The sandbox instance
    #
    # @example Connect to existing sandbox
    #   sandbox = client.connect("abc123")
    #
    # @example Connect and extend timeout
    #   sandbox = client.connect("abc123", timeout_ms: 3_600_000)
    def connect(sandbox_id, timeout_ms: nil)
      # If timeout provided, use connect endpoint to extend TTL
      if timeout_ms
        # E2B API expects timeout in seconds
        timeout_seconds = (timeout_ms / 1000).to_i
        response = @http_client.post("/sandboxes/#{sandbox_id}/connect", body: {
          timeout: timeout_seconds
        })
      else
        response = @http_client.get("/sandboxes/#{sandbox_id}")
      end

      Sandbox.new(
        sandbox_data: response,
        http_client: @http_client,
        api_key: @config.api_key,
        domain: @domain
      )
    end

    # Get sandbox details
    #
    # @param sandbox_id [String] The sandbox ID
    # @return [Sandbox] The sandbox instance
    def get(sandbox_id)
      response = @http_client.get("/sandboxes/#{sandbox_id}")

      Sandbox.new(
        sandbox_data: response,
        http_client: @http_client,
        api_key: @config.api_key,
        domain: @domain
      )
    end

    # List all running sandboxes
    #
    # @param metadata [Hash, nil] Filter by metadata
    # @param state [String, nil] Filter by state (e.g., "running", "paused")
    # @param limit [Integer] Maximum results
    # @param page [Integer] Page number
    #
    # @return [Array<Sandbox>] List of sandbox instances
    #
    # @example List all sandboxes
    #   sandboxes = client.list
    #
    # @example Filter by metadata
    #   sandboxes = client.list(metadata: { "user" => "123" })
    def list(metadata: nil, state: nil, limit: 100, page: 1)
      params = { limit: limit }
      params[:metadata] = metadata.to_json if metadata
      params[:state] = state if state
      params[:page] = page if page > 1

      # Use v2 API for better filtering
      response = @http_client.get("/v2/sandboxes", params: params)

      # Handle both array response and hash with "sandboxes" key
      sandboxes = if response.is_a?(Array)
                    response
                  elsif response.is_a?(Hash)
                    response["sandboxes"] || response[:sandboxes] || []
                  else
                    []
                  end
      sandboxes = [sandboxes] unless sandboxes.is_a?(Array)

      sandboxes.map do |sandbox_data|
        Sandbox.new(
          sandbox_data: sandbox_data,
          http_client: @http_client,
          api_key: @config.api_key,
          domain: @domain
        )
      end
    end

    # Kill a sandbox by ID
    #
    # @param sandbox_id [String] The sandbox ID to kill
    # @return [Boolean] True if killed successfully
    def kill(sandbox_id)
      @http_client.delete("/sandboxes/#{sandbox_id}")
      true
    rescue NotFoundError
      # Already killed/doesn't exist
      true
    end

    # Set sandbox timeout
    #
    # @param sandbox_id [String] The sandbox ID
    # @param timeout_ms [Integer] Timeout in milliseconds
    def set_timeout(sandbox_id, timeout_ms)
      # E2B API expects timeout in seconds
      timeout_seconds = (timeout_ms / 1000).to_i
      @http_client.post("/sandboxes/#{sandbox_id}/timeout", body: {
        timeout: timeout_seconds
      })
    end

    # Pause a sandbox
    #
    # @param sandbox_id [String] The sandbox ID
    def pause(sandbox_id)
      @http_client.post("/sandboxes/#{sandbox_id}/pause")
    end

    # Resume a sandbox
    #
    # @param sandbox_id [String] The sandbox ID
    # @param timeout_ms [Integer, nil] New timeout in milliseconds
    # @return [Sandbox] The resumed sandbox
    def resume(sandbox_id, timeout_ms: nil)
      body = {}
      # E2B API expects timeout in seconds
      body[:timeout] = (timeout_ms / 1000).to_i if timeout_ms

      response = @http_client.post("/sandboxes/#{sandbox_id}/connect", body: body)

      Sandbox.new(
        sandbox_data: response,
        http_client: @http_client,
        api_key: @config.api_key,
        domain: @domain
      )
    end

    # Get metrics for multiple sandboxes
    #
    # @param sandbox_ids [Array<String>] List of sandbox IDs (max 100)
    # @return [Hash{String => Hash}] Metrics keyed by sandbox ID
    def batch_metrics(sandbox_ids)
      raise ArgumentError, "Maximum 100 sandbox IDs" if sandbox_ids.length > 100

      response = @http_client.post("/sandboxes/metrics", body: {
        sandboxIDs: sandbox_ids
      })

      response["metrics"] || response[:metrics] || {}
    end

    private

    def resolve_config(config_or_options)
      case config_or_options
      when Configuration
        config_or_options
      when Hash
        Configuration.new(**config_or_options)
      when nil
        E2B.configuration || Configuration.new
      else
        raise ArgumentError, "Expected Configuration, Hash, or nil"
      end
    end
  end
end
