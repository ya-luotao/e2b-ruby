# frozen_string_literal: true

module E2B
  # Client for interacting with the E2B API
  #
  # This class provides a convenient wrapper around {Sandbox} class methods.
  # For the most direct API (matching the official SDK pattern), use
  # {Sandbox.create}, {Sandbox.connect}, etc. directly.
  #
  # @example Using Client
  #   client = E2B::Client.new(api_key: "your-api-key")
  #   sandbox = client.create(template: "base")
  #
  # @example Using Sandbox directly (recommended, matches official SDK)
  #   sandbox = E2B::Sandbox.create(template: "base", api_key: "your-key")
  class Client
    # @return [Configuration] Client configuration
    attr_reader :config

    # Initialize a new E2B client
    #
    # @param config_or_options [Configuration, Hash, nil] Configuration or options hash
    # @option config_or_options [String] :api_key API key for authentication
    # @option config_or_options [String] :api_url API URL
    # @option config_or_options [Integer] :timeout_ms Request timeout in milliseconds
    def initialize(config_or_options = nil)
      @config = resolve_config(config_or_options)
      @config.validate!

      @http_client = API::HttpClient.new(
        base_url: @config.api_url,
        api_key: @config.api_key,
        access_token: @config.access_token,
        logger: @config.logger
      )

      @domain = @config.domain
    end

    # Create a new sandbox
    #
    # @param template [String] Template ID or alias
    # @param timeout [Integer, nil] Sandbox timeout in seconds (or timeout_ms in milliseconds for backward compat)
    # @param timeout_ms [Integer, nil] Sandbox timeout in milliseconds (deprecated, use timeout in seconds)
    # @param metadata [Hash, nil] Custom metadata
    # @param envs [Hash{String => String}, nil] Environment variables
    # @return [Sandbox] The created sandbox instance
    def create(template: "base", timeout: nil, timeout_ms: nil, metadata: nil, envs: nil,
               secure: true, allow_internet_access: true, network: nil,
               lifecycle: nil, auto_pause: nil, mcp: nil, request_timeout: nil, **_opts)
      # Support both seconds and milliseconds for backward compat
      timeout_seconds = if timeout
                          timeout
                        elsif timeout_ms
                          (timeout_ms / 1000).to_i
                        else
                          (@config.sandbox_timeout_ms / 1000).to_i
                        end
      template = resolved_template(template, mcp: mcp)
      lifecycle = normalized_lifecycle(lifecycle: lifecycle, auto_pause: auto_pause)

      body = {
        templateID: template,
        timeout: timeout_seconds,
        secure: secure,
        allow_internet_access: allow_internet_access,
        autoPause: lifecycle[:on_timeout] == "pause"
      }
      body[:metadata] = metadata if metadata
      body[:envVars] = envs if envs
      body[:mcp] = mcp if mcp
      body[:network] = network if network
      if body[:autoPause]
        body[:autoResume] = { enabled: lifecycle[:auto_resume] }
      end

      response = @http_client.post("/sandboxes", body: body, timeout: request_timeout || @config.request_timeout || 120)

      sandbox = Sandbox.new(
        sandbox_data: response,
        http_client: @http_client,
        api_key: @config.api_key,
        domain: @domain
      )

      start_mcp_gateway(sandbox, mcp) if mcp

      sandbox
    end

    # Connect to an existing sandbox
    #
    # @param sandbox_id [String] The sandbox ID
    # @param timeout [Integer, nil] Timeout in seconds
    # @return [Sandbox]
    def connect(sandbox_id, timeout: nil)
      timeout_seconds = timeout || ((@config.sandbox_timeout_ms || (Sandbox::DEFAULT_TIMEOUT * 1000)) / 1000).to_i
      response = @http_client.post("/sandboxes/#{sandbox_id}/connect",
        body: { timeout: timeout_seconds })

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
    # @return [Sandbox]
    def get(sandbox_id)
      response = @http_client.get("/sandboxes/#{sandbox_id}")

      Sandbox.new(
        sandbox_data: response,
        http_client: @http_client,
        api_key: @config.api_key,
        domain: @domain
      )
    end

    # List sandboxes
    #
    # @param metadata [Hash, nil] Filter by metadata
    # @param state [String, nil] Filter by state
    # @param limit [Integer] Maximum results
    # @return [SandboxPaginator]
    def list(metadata: nil, state: nil, limit: 100, next_token: nil)
      query = {}
      query[:metadata] = metadata if metadata
      query[:state] = state if state

      SandboxPaginator.new(
        http_client: @http_client,
        query: query.empty? ? nil : query,
        limit: limit,
        next_token: next_token
      )
    end

    # Kill a sandbox
    #
    # @param sandbox_id [String] The sandbox ID
    # @return [Boolean]
    def kill(sandbox_id)
      @http_client.delete("/sandboxes/#{sandbox_id}")
      true
    rescue NotFoundError
      true
    end

    # Set sandbox timeout
    #
    # @param sandbox_id [String] The sandbox ID
    # @param timeout [Integer] Timeout in seconds
    def set_timeout(sandbox_id, timeout)
      @http_client.post("/sandboxes/#{sandbox_id}/timeout",
        body: { timeout: timeout })
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
    # @param timeout [Integer, nil] New timeout in seconds
    # @return [Sandbox]
    def resume(sandbox_id, timeout: nil)
      timeout_seconds = timeout || ((@config.sandbox_timeout_ms || (Sandbox::DEFAULT_TIMEOUT * 1000)) / 1000).to_i
      body = { timeout: timeout_seconds }

      response = @http_client.post("/sandboxes/#{sandbox_id}/connect", body: body)

      Sandbox.new(
        sandbox_data: response,
        http_client: @http_client,
        api_key: @config.api_key,
        domain: @domain
      )
    end

    # List snapshots for the team, optionally filtered by source sandbox.
    #
    # @param sandbox_id [String, nil] Filter snapshots by source sandbox ID
    # @param limit [Integer] Maximum results per page
    # @param next_token [String, nil] Pagination token
    # @return [SnapshotPaginator]
    def list_snapshots(sandbox_id: nil, limit: 100, next_token: nil)
      SnapshotPaginator.new(
        http_client: @http_client,
        sandbox_id: sandbox_id,
        limit: limit,
        next_token: next_token
      )
    end

    # Delete a snapshot template.
    #
    # @param snapshot_id [String] Snapshot identifier
    # @return [Boolean]
    def delete_snapshot(snapshot_id)
      @http_client.delete("/templates/#{snapshot_id}")
      true
    rescue NotFoundError
      false
    end

    private

    def resolved_template(template, mcp:)
      return template unless template.nil? || template.empty?

      return Sandbox::DEFAULT_MCP_TEMPLATE if mcp

      @config.default_template || "base"
    end

    def normalized_lifecycle(lifecycle:, auto_pause:)
      raw_lifecycle = lifecycle || {
        on_timeout: auto_pause ? "pause" : "kill",
        auto_resume: false
      }

      on_timeout = raw_lifecycle[:on_timeout] || raw_lifecycle["on_timeout"] || "kill"
      unless %w[kill pause].include?(on_timeout)
        raise ArgumentError, "Lifecycle on_timeout must be 'kill' or 'pause'"
      end

      auto_resume = if raw_lifecycle.key?(:auto_resume)
                      raw_lifecycle[:auto_resume]
                    else
                      raw_lifecycle["auto_resume"]
                    end

      {
        on_timeout: on_timeout,
        auto_resume: on_timeout == "pause" ? !!auto_resume : false
      }
    end

    def start_mcp_gateway(sandbox, mcp)
      token = SecureRandom.uuid
      sandbox.instance_variable_set(:@mcp_token, token)
      sandbox.commands.run(
        "mcp-gateway --config '#{JSON.generate(mcp)}'",
        user: "root",
        envs: { "GATEWAY_ACCESS_TOKEN" => token }
      )
    end

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
