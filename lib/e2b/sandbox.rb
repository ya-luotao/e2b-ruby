# frozen_string_literal: true

require "time"
require "securerandom"
require "base64"
require "digest"
require "json"

module E2B
  # Represents an E2B Sandbox instance
  #
  # A Sandbox is an isolated cloud environment for running code, executing
  # commands, and managing files securely. Create sandboxes using class methods
  # or through {E2B::Client}.
  #
  # @example Create and use a sandbox
  #   sandbox = E2B::Sandbox.create(template: "base", api_key: "your-key")
  #
  #   result = sandbox.commands.run("echo 'Hello'")
  #   puts result.stdout
  #
  #   sandbox.files.write("/home/user/hello.txt", "Hello!")
  #   sandbox.kill
  #
  # @example Connect to an existing sandbox
  #   sandbox = E2B::Sandbox.connect("sandbox-id", api_key: "your-key")
  #   sandbox.commands.run("ls")
  class Sandbox
    # Default domain for E2B sandboxes
    DEFAULT_DOMAIN = "e2b.app"

    # Default sandbox timeout in seconds
    DEFAULT_TIMEOUT = 300

    # Default template used when enabling MCP without an explicit template.
    DEFAULT_MCP_TEMPLATE = "mcp-gateway"

    # MCP gateway port.
    MCP_PORT = 50005

    # @return [String] Unique sandbox ID
    attr_reader :sandbox_id

    # @return [String] Template ID used to create this sandbox
    attr_reader :template_id

    # @return [String, nil] Sandbox alias/name
    attr_reader :alias_name

    # @return [String] Client ID
    attr_reader :client_id

    # @return [Time, nil] When the sandbox was started
    attr_reader :started_at

    # @return [Time, nil] When the sandbox will timeout
    attr_reader :end_at

    # @return [Integer, nil] CPU count
    attr_reader :cpu_count

    # @return [Integer, nil] Memory in MB
    attr_reader :memory_mb

    # @return [Hash] Metadata
    attr_reader :metadata

    # @return [String, nil] Current sandbox state
    attr_reader :state

    # @return [String, nil] Envd version reported by the control plane
    attr_reader :envd_version

    # @return [String, nil] Access token for envd authentication
    attr_reader :envd_access_token

    # @return [String, nil] Access token required for proxied public traffic
    attr_reader :traffic_access_token

    # @return [Services::Commands] Command execution service
    attr_reader :commands

    # @return [Services::Filesystem] Filesystem service
    attr_reader :files

    # @return [Services::Pty] PTY (pseudo-terminal) service
    attr_reader :pty

    # @return [Services::Git] Git operations service
    attr_reader :git

    # -------------------------------------------------------------------
    # Class methods (matching official SDK pattern)
    # -------------------------------------------------------------------

    class << self
      # Create a new sandbox
      #
      # @param template [String] Template ID or alias (default: "base")
      # @param timeout [Integer] Sandbox timeout in seconds (default: 300)
      # @param metadata [Hash, nil] Custom metadata key-value pairs
      # @param envs [Hash{String => String}, nil] Environment variables
      # @param api_key [String, nil] API key (defaults to E2B_API_KEY env var)
      # @param domain [String] E2B domain
      # @param request_timeout [Integer] HTTP request timeout in seconds
      # @return [Sandbox] The created sandbox instance
      #
      # @example
      #   sandbox = E2B::Sandbox.create(template: "base")
      #   sandbox = E2B::Sandbox.create(template: "python", timeout: 600)
      def create(template: "base", timeout: DEFAULT_TIMEOUT, metadata: nil,
                 envs: nil, secure: true, allow_internet_access: true,
                 network: nil, lifecycle: nil, auto_pause: nil, mcp: nil,
                 api_key: nil, access_token: nil, domain: nil,
                 request_timeout: 120)
        credentials = resolve_credentials(api_key: api_key, access_token: access_token)
        domain = resolve_domain(domain)
        http_client = build_http_client(**credentials, domain: domain)
        template = resolved_template(template, mcp: mcp)
        lifecycle = normalized_lifecycle(lifecycle: lifecycle, auto_pause: auto_pause)

        body = {
          templateID: template,
          timeout: timeout,
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

        response = http_client.post("/sandboxes", body: body, timeout: request_timeout)

        sandbox = new(
          sandbox_data: response,
          http_client: http_client,
          api_key: credentials[:api_key],
          domain: domain
        )

        start_mcp_gateway(sandbox, mcp) if mcp

        sandbox
      end

      # Connect to an existing running sandbox
      #
      # @param sandbox_id [String] The sandbox ID to connect to
      # @param timeout [Integer, nil] New timeout in seconds (extends TTL)
      # @param api_key [String, nil] API key
      # @param domain [String] E2B domain
      # @return [Sandbox] The sandbox instance
      def connect(sandbox_id, timeout: DEFAULT_TIMEOUT, api_key: nil, access_token: nil, domain: nil)
        credentials = resolve_credentials(api_key: api_key, access_token: access_token)
        domain = resolve_domain(domain)
        http_client = build_http_client(**credentials, domain: domain)

        response = http_client.post("/sandboxes/#{sandbox_id}/connect",
          body: { timeout: timeout || DEFAULT_TIMEOUT })

        new(
          sandbox_data: response,
          http_client: http_client,
          api_key: credentials[:api_key],
          domain: domain
        )
      end

      # List running sandboxes
      #
      # @param query [Hash, nil] Filter parameters (metadata, state)
      # @param limit [Integer] Maximum results per page
      # @param next_token [String, nil] Pagination token
      # @param api_key [String, nil] API key
      # @return [Array<Hash>] List of sandbox info hashes
      def list(query: nil, limit: 100, next_token: nil, api_key: nil, access_token: nil, domain: nil)
        credentials = resolve_credentials(api_key: api_key, access_token: access_token)
        http_client = build_http_client(**credentials, domain: resolve_domain(domain))

        SandboxPaginator.new(
          http_client: http_client,
          query: query,
          limit: limit,
          next_token: next_token
        )
      end

      # List snapshots for the team, optionally filtered by source sandbox.
      #
      # @param sandbox_id [String, nil] Filter snapshots by source sandbox ID
      # @param limit [Integer] Maximum results per page
      # @param next_token [String, nil] Pagination token
      # @return [SnapshotPaginator]
      def list_snapshots(sandbox_id: nil, limit: 100, next_token: nil, api_key: nil, access_token: nil, domain: nil)
        credentials = resolve_credentials(api_key: api_key, access_token: access_token)
        http_client = build_http_client(**credentials, domain: resolve_domain(domain))

        SnapshotPaginator.new(
          http_client: http_client,
          sandbox_id: sandbox_id,
          limit: limit,
          next_token: next_token
        )
      end

      # Delete a snapshot template.
      #
      # @param snapshot_id [String] Snapshot identifier
      # @return [Boolean] true if deleted, false if not found
      def delete_snapshot(snapshot_id, api_key: nil, access_token: nil, domain: nil)
        credentials = resolve_credentials(api_key: api_key, access_token: access_token)
        http_client = build_http_client(**credentials, domain: resolve_domain(domain))
        http_client.delete("/templates/#{snapshot_id}")
        true
      rescue E2B::NotFoundError
        false
      end

      # Kill a sandbox by ID
      #
      # @param sandbox_id [String] Sandbox ID to kill
      # @param api_key [String, nil] API key
      def kill(sandbox_id, api_key: nil, access_token: nil, domain: nil)
        credentials = resolve_credentials(api_key: api_key, access_token: access_token)
        http_client = build_http_client(**credentials, domain: resolve_domain(domain))
        http_client.delete("/sandboxes/#{sandbox_id}")
        true
      rescue E2B::NotFoundError
        true
      end

      private

      def resolved_template(template, mcp:)
        return template unless template.nil? || template.empty?

        return DEFAULT_MCP_TEMPLATE if mcp

        E2B.configuration&.default_template || "base"
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

      def resolve_credentials(api_key:, access_token:)
        resolved_api_key = api_key || E2B.configuration&.api_key || ENV["E2B_API_KEY"]
        resolved_access_token = access_token || E2B.configuration&.access_token || ENV["E2B_ACCESS_TOKEN"]

        unless (resolved_api_key && !resolved_api_key.empty?) || (resolved_access_token && !resolved_access_token.empty?)
          raise ConfigurationError,
            "E2B credentials are required. Set E2B_API_KEY or E2B_ACCESS_TOKEN, or pass api_key:/access_token:."
        end

        { api_key: resolved_api_key, access_token: resolved_access_token }
      end

      def resolve_domain(domain)
        domain || E2B.configuration&.domain || ENV["E2B_DOMAIN"] || Configuration::DEFAULT_DOMAIN
      end

      def build_http_client(api_key:, access_token:, domain:)
        config = E2B.configuration
        base_url = config&.api_url || ENV["E2B_API_URL"] || Configuration.default_api_url(domain)
        API::HttpClient.new(
          base_url: base_url,
          api_key: api_key,
          access_token: access_token,
          logger: config&.logger
        )
      end
    end

    # -------------------------------------------------------------------
    # Instance methods
    # -------------------------------------------------------------------

    # Initialize a new Sandbox instance
    #
    # @param sandbox_data [Hash] Sandbox data from API response
    # @param http_client [API::HttpClient] HTTP client for API calls
    # @param api_key [String] API key for authentication
    # @param domain [String] E2B domain
    def initialize(sandbox_data:, http_client:, api_key:, domain: DEFAULT_DOMAIN)
      @http_client = http_client
      @api_key = api_key
      @domain = domain

      process_sandbox_data(sandbox_data)
      initialize_services
    end

    # Get sandbox info from the API
    #
    # @return [Hash] Sandbox info
    def get_info
      response = @http_client.get("/sandboxes/#{@sandbox_id}")
      process_sandbox_data(response)
      response
    end

    # Check if the sandbox is running
    #
    # @param request_timeout [Integer] Request timeout in seconds
    # @return [Boolean]
    def running?(request_timeout: 10)
      return false if @end_at && Time.now >= @end_at

      get_info
      @state != "paused"
    rescue NotFoundError, E2BError
      false
    end

    # Set the sandbox timeout
    #
    # @param timeout [Integer] Timeout in seconds
    def set_timeout(timeout)
      raise ArgumentError, "Timeout must be positive" if timeout <= 0
      raise ArgumentError, "Timeout cannot exceed 24 hours (86400s)" if timeout > 86_400

      @http_client.post("/sandboxes/#{@sandbox_id}/timeout",
        body: { timeout: timeout })

      @end_at = Time.now + timeout
    end

    # Kill/terminate the sandbox
    def kill
      @http_client.delete("/sandboxes/#{@sandbox_id}")
    end

    # Pause the sandbox (saves state for later resume)
    def pause
      @http_client.post("/sandboxes/#{@sandbox_id}/pause")
      @state = "paused"
    end

    # Resume a paused sandbox
    #
    # @param timeout [Integer, nil] New timeout in seconds
    def resume(timeout: nil)
      body = { timeout: timeout || DEFAULT_TIMEOUT }

      response = @http_client.post("/sandboxes/#{@sandbox_id}/connect", body: body)
      process_sandbox_data(response) if response.is_a?(Hash)
    end

    # Create a snapshot of the sandbox
    #
    # @return [Hash] Snapshot info with snapshot_id
    def create_snapshot
      response = @http_client.post("/sandboxes/#{@sandbox_id}/snapshots")
      Models::SnapshotInfo.from_hash(response)
    end

    # List snapshots that were created from this sandbox.
    #
    # @param limit [Integer] Maximum results per page
    # @param next_token [String, nil] Pagination token
    # @return [SnapshotPaginator]
    def list_snapshots(limit: 100, next_token: nil)
      self.class.list_snapshots(
        sandbox_id: @sandbox_id,
        limit: limit,
        next_token: next_token,
        api_key: @api_key,
        domain: @domain
      )
    end

    # Get the MCP URL for the sandbox.
    #
    # @return [String]
    def get_mcp_url
      "https://#{get_host(MCP_PORT)}/mcp"
    end

    # Get the MCP token for the sandbox.
    #
    # @return [String, nil]
    def get_mcp_token
      @mcp_token ||= @files.read("/etc/mcp-gateway/.token", user: "root")
    end

    # Get the host string for a port (without protocol)
    #
    # @param port [Integer] Port number
    # @return [String] Host string like "4321-abc123.e2b.app"
    def get_host(port)
      "#{port}-#{@sandbox_id}.#{@domain}"
    end

    # Get full URL for a port
    #
    # @param port [Integer] Port number
    # @return [String] Full URL like "https://4321-abc123.e2b.app"
    def get_url(port)
      "https://#{get_host(port)}"
    end

    # Get URL for downloading a file
    #
    # @param path [String] File path in the sandbox
    # @param user [String, nil] Username context
    # @return [String] Download URL
    def download_url(path, user: nil, use_signature_expiration: nil)
      query = build_file_url_query(
        path: path,
        user: user,
        operation: "read",
        use_signature_expiration: use_signature_expiration
      )
      base = "https://#{Services::BaseService::ENVD_PORT}-#{@sandbox_id}.#{@domain}/files"
      query.empty? ? base : "#{base}?#{URI.encode_www_form(query)}"
    end

    # Get URL for uploading a file
    #
    # @param path [String, nil] Destination path
    # @param user [String, nil] Username context
    # @return [String] Upload URL
    def upload_url(path = nil, user: nil, use_signature_expiration: nil)
      base = "https://#{Services::BaseService::ENVD_PORT}-#{@sandbox_id}.#{@domain}/files"
      query = build_file_url_query(
        path: path,
        user: user,
        operation: "write",
        use_signature_expiration: use_signature_expiration
      )
      query.empty? ? base : "#{base}?#{URI.encode_www_form(query)}"
    end

    # Get sandbox metrics (CPU, memory, disk usage)
    #
    # @param start_time [Time, nil] Metrics start time
    # @param end_time [Time, nil] Metrics end time
    # @return [Array<Hash>] Metrics data
    def get_metrics(start_time: nil, end_time: nil)
      params = {}
      params[:start] = start_time.iso8601 if start_time
      params[:end] = end_time.iso8601 if end_time

      @http_client.get("/sandboxes/#{@sandbox_id}/metrics", params: params)
    end

    # Get sandbox logs
    #
    # @param start_time [Time, nil] Start time for logs
    # @param limit [Integer] Maximum number of log entries
    # @return [Array<Hash>] Log entries
    def logs(start_time: nil, limit: 100)
      params = { limit: limit }
      params[:start] = start_time.iso8601 if start_time

      response = @http_client.get("/sandboxes/#{@sandbox_id}/logs", params: params)
      response.is_a?(Hash) ? (response["logs"] || []) : response
    end

    # Time remaining until sandbox timeout
    #
    # @return [Integer] Seconds remaining, 0 if expired or unknown
    def time_remaining
      return 0 if @end_at.nil?

      remaining = (@end_at - Time.now).to_i
      remaining.positive? ? remaining : 0
    end

    # Alias for sandbox_id
    alias id sandbox_id

    private

    def process_sandbox_data(data)
      return unless data.is_a?(Hash)

      @sandbox_id = data["sandboxID"] || data["sandbox_id"] || data[:sandboxID] || @sandbox_id
      @template_id = data["templateID"] || data["template_id"] || data[:templateID] || @template_id
      @alias_name = data["alias"] || data[:alias]
      @client_id = data["clientID"] || data["client_id"] || data[:clientID]
      @cpu_count = data["cpuCount"] || data["cpu_count"] || data[:cpuCount]
      @memory_mb = data["memoryMB"] || data["memory_mb"] || data[:memoryMB]
      @metadata = data["metadata"] || data[:metadata] || {}
      @state = data["state"] || data[:state] || @state
      @domain = data["domain"] || data[:domain] || @domain

      @envd_version = data["envdVersion"] || data["envd_version"] || data[:envdVersion] || @envd_version
      @envd_access_token = data["envdAccessToken"] || data["envd_access_token"] || data[:envdAccessToken] || @envd_access_token
      @traffic_access_token = data["trafficAccessToken"] || data["traffic_access_token"] || data[:trafficAccessToken] || @traffic_access_token

      @started_at = parse_time(data["startedAt"] || data["started_at"] || data[:startedAt])
      @end_at = parse_time(data["endAt"] || data["end_at"] || data[:endAt])
    end

    def initialize_services
      service_opts = {
        sandbox_id: @sandbox_id,
        sandbox_domain: @domain,
        api_key: @api_key,
        access_token: @envd_access_token
      }

      @commands = Services::Commands.new(**service_opts)

      @files = Services::Filesystem.new(**service_opts)

      @pty = Services::Pty.new(**service_opts)

      @git = Services::Git.new(commands: @commands)
    end

    def parse_time(value)
      return nil if value.nil?
      return value if value.is_a?(Time)

      Time.parse(value)
    rescue ArgumentError
      nil
    end

    def build_file_url_query(path:, user:, operation:, use_signature_expiration:)
      if use_signature_expiration && !@envd_access_token
        raise ArgumentError, "Signature expiration can be used only when the sandbox is secured"
      end

      query = []
      query << ["path", path] if path
      query << ["username", user] if user

      signature = file_signature(
        path: path || "",
        operation: operation,
        user: user,
        expiration_in_seconds: use_signature_expiration
      )

      return query unless signature

      query << ["signature", signature[:signature]]
      query << ["signature_expiration", signature[:expiration].to_s] if signature[:expiration]
      query
    end

    def file_signature(path:, operation:, user:, expiration_in_seconds:)
      return nil unless @envd_access_token

      expiration = expiration_in_seconds ? Time.now.to_i + expiration_in_seconds : nil
      raw_user = user || ""
      raw = if expiration
              "#{path}:#{operation}:#{raw_user}:#{@envd_access_token}:#{expiration}"
            else
              "#{path}:#{operation}:#{raw_user}:#{@envd_access_token}"
            end

      digest = Digest::SHA256.digest(raw)
      encoded = Base64.strict_encode64(digest).sub(/=+\z/, "")

      { signature: "v1_#{encoded}", expiration: expiration }
    end
  end
end
