# frozen_string_literal: true

module E2B
  # Represents an E2B Sandbox instance
  #
  # A Sandbox is an isolated cloud environment that can be used to
  # run code, execute commands, and manage files securely.
  #
  # @example Basic usage
  #   sandbox = client.create(template: "base")
  #
  #   # Execute commands
  #   result = sandbox.commands.run("echo 'Hello'")
  #   puts result.stdout
  #
  #   # Work with files
  #   sandbox.files.write("/home/user/hello.txt", "Hello!")
  #
  #   # Keep alive
  #   sandbox.set_timeout(3600_000)  # 1 hour
  #
  #   # Clean up
  #   sandbox.kill
  class Sandbox
    # Default domain for E2B sandboxes
    DEFAULT_DOMAIN = "e2b.app"

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

    # @return [String, nil] Access token for envd authentication
    attr_reader :envd_access_token

    # @return [Services::Commands] Command execution service
    attr_reader :commands

    # @return [Services::Filesystem] Filesystem service
    attr_reader :files

    # Initialize a new Sandbox instance
    #
    # @param sandbox_data [Hash] Sandbox data from API
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

    # Refresh sandbox data from the API
    def refresh
      response = @http_client.get("/sandboxes/#{@sandbox_id}")
      process_sandbox_data(response)
    end

    # Check if the sandbox is running
    #
    # @return [Boolean]
    def running?
      return false if @end_at && Time.now >= @end_at

      # Refresh and check
      begin
        refresh
        true
      rescue NotFoundError
        false
      end
    end

    # Set the sandbox timeout
    #
    # @param timeout_ms [Integer] Timeout in milliseconds (max 24 hours = 86_400_000)
    #
    # @example Extend by 1 hour
    #   sandbox.set_timeout(3_600_000)
    def set_timeout(timeout_ms)
      raise ArgumentError, "Timeout must be positive" if timeout_ms <= 0
      raise ArgumentError, "Timeout cannot exceed 24 hours" if timeout_ms > 86_400_000

      # E2B API expects timeout in seconds
      timeout_seconds = (timeout_ms / 1000).to_i
      @http_client.post("/sandboxes/#{@sandbox_id}/timeout", body: {
        timeout: timeout_seconds
      })

      # Update local end_at
      @end_at = Time.now + (timeout_ms / 1000.0)
    end

    # Keep the sandbox alive by extending timeout
    #
    # @param duration_ms [Integer] Duration to extend by (default: 1 hour)
    def keep_alive(duration_ms: 3_600_000)
      set_timeout(duration_ms)
    end

    # Kill/terminate the sandbox
    def kill
      @http_client.delete("/sandboxes/#{@sandbox_id}")
    end

    # Pause the sandbox (saves state for later resume)
    def pause
      @http_client.post("/sandboxes/#{@sandbox_id}/pause")
    end

    # Resume a paused sandbox
    #
    # @param timeout_ms [Integer, nil] New timeout in milliseconds
    def resume(timeout_ms: nil)
      body = {}
      # E2B API expects timeout in seconds
      body[:timeout] = (timeout_ms / 1000).to_i if timeout_ms

      response = @http_client.post("/sandboxes/#{@sandbox_id}/connect", body: body)
      process_sandbox_data(response) if response.is_a?(Hash)
    end

    # Get the public URL for a port
    #
    # @param port [Integer] Port number
    # @return [String] Public URL for the port
    #
    # @example Get URL for dev server on port 4321
    #   url = sandbox.get_host(4321)
    #   # => "https://4321-abc123.e2b.app"
    def get_host(port)
      # E2B URL format: https://{port}-{sandboxId}.{domain}
      "https://#{port}-#{@sandbox_id}.#{@domain}"
    end

    # Get URL for downloading a file
    #
    # @param path [String] File path in the sandbox
    # @return [String] Download URL
    def download_url(path)
      encoded_path = URI.encode_www_form_component(path)
      # E2B URL format: https://{port}-{sandboxId}.{domain}
      "https://#{Services::BaseService::ENVD_PORT}-#{@sandbox_id}.#{@domain}/files/download?path=#{encoded_path}"
    end

    # Get URL for uploading a file
    #
    # @param path [String, nil] Destination path (defaults to home directory)
    # @return [String] Upload URL
    def upload_url(path = nil)
      # E2B URL format: https://{port}-{sandboxId}.{domain}
      base = "https://#{Services::BaseService::ENVD_PORT}-#{@sandbox_id}.#{@domain}/files/upload"
      path ? "#{base}?path=#{URI.encode_www_form_component(path)}" : base
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
      response["logs"] || response[:logs] || []
    end

    # Get sandbox metrics (CPU, memory, disk usage)
    #
    # @return [Hash] Metrics data
    def metrics
      @http_client.get("/sandboxes/#{@sandbox_id}/metrics")
    end

    # Time remaining until sandbox timeout
    #
    # @return [Integer] Seconds remaining, 0 if expired or unknown
    def time_remaining
      return 0 if @end_at.nil?

      remaining = (@end_at - Time.now).to_i
      remaining.positive? ? remaining : 0
    end

    # Alias for sandbox_id for compatibility
    alias id sandbox_id

    private

    def process_sandbox_data(data)
      return unless data.is_a?(Hash)

      # Debug logging
      Rails.logger.info "[E2B::Sandbox] Processing sandbox data keys: #{data.keys.inspect}" if defined?(Rails)

      @sandbox_id = data["sandboxID"] || data["sandbox_id"] || data[:sandboxID] || @sandbox_id
      @template_id = data["templateID"] || data["template_id"] || data[:templateID] || @template_id
      @alias_name = data["alias"] || data[:alias]
      @client_id = data["clientID"] || data["client_id"] || data[:clientID]
      @cpu_count = data["cpuCount"] || data["cpu_count"] || data[:cpuCount]
      @memory_mb = data["memoryMB"] || data["memory_mb"] || data[:memoryMB]
      @metadata = data["metadata"] || data[:metadata] || {}

      # Extract envd access token for authentication
      @envd_access_token = data["envdAccessToken"] || data["envd_access_token"] || data[:envdAccessToken] || @envd_access_token

      # Debug logging
      Rails.logger.info "[E2B::Sandbox] Sandbox ID: #{@sandbox_id}, envdAccessToken present: #{@envd_access_token.present?}" if defined?(Rails)

      @started_at = parse_time(data["startedAt"] || data["started_at"] || data[:startedAt])
      @end_at = parse_time(data["endAt"] || data["end_at"] || data[:endAt])
    end

    def initialize_services
      @commands = Services::Commands.new(
        sandbox_id: @sandbox_id,
        sandbox_domain: @domain,
        api_key: @api_key,
        access_token: @envd_access_token
      )

      @files = Services::Filesystem.new(
        sandbox_id: @sandbox_id,
        sandbox_domain: @domain,
        api_key: @api_key,
        access_token: @envd_access_token
      )
    end

    def parse_time(value)
      return nil if value.nil?
      return value if value.is_a?(Time)

      Time.parse(value)
    rescue ArgumentError
      nil
    end
  end
end
