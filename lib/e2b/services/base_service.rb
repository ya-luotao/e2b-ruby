# frozen_string_literal: true

require "base64"
require "net/http"
require "openssl"
require "ostruct"

module E2B
  module Services
    # Base class for sandbox services
    #
    # E2B sandboxes expose services through the envd daemon on port 49983.
    # This base class handles communication with that daemon.
    class BaseService
      # Default envd port
      ENVD_PORT = 49983

      # @param sandbox_id [String] Sandbox ID
      # @param sandbox_domain [String] Sandbox domain (e.g., "e2b.app")
      # @param api_key [String] API key for authentication
      # @param access_token [String, nil] Sandbox-specific access token
      # @param logger [Logger, nil] Optional logger
      def initialize(sandbox_id:, sandbox_domain:, api_key:, access_token: nil, logger: nil)
        @sandbox_id = sandbox_id
        @sandbox_domain = sandbox_domain
        @api_key = api_key
        @access_token = access_token
        @logger = logger
        @envd_client = nil
      end

      protected

      # Get the envd HTTP client for this sandbox
      #
      # @return [API::HttpClient]
      def envd_client
        @envd_client ||= build_envd_client
      end

      # Perform GET request to envd
      #
      # @param path [String] API path
      # @param params [Hash] Query parameters
      # @param timeout [Integer] Request timeout in seconds
      # @return [Hash, Array, String] Response
      def envd_get(path, params: {}, timeout: 120)
        envd_client.get(path, params: params, timeout: timeout)
      end

      # Perform POST request to envd
      #
      # @param path [String] API path
      # @param body [Hash, nil] Request body
      # @param timeout [Integer] Request timeout in seconds
      # @return [Hash, Array, String] Response
      def envd_post(path, body: nil, timeout: 120)
        envd_client.post(path, body: body, timeout: timeout)
      end

      # Perform DELETE request to envd
      #
      # @param path [String] API path
      # @param timeout [Integer] Request timeout in seconds
      # @return [Hash, Array, String, nil] Response
      def envd_delete(path, timeout: 120)
        envd_client.delete(path, timeout: timeout)
      end

      # Perform Connect RPC call to envd
      #
      # Connect RPC uses POST with JSON body to paths like /package.Service/Method
      #
      # @param service [String] Service name (e.g., "process.Process")
      # @param method [String] Method name (e.g., "Start")
      # @param body [Hash] Request body
      # @param timeout [Integer] Request timeout in seconds
      # @param on_event [Proc, nil] Callback for streaming events
      # @return [Hash] Response
      def envd_rpc(service, method, body: {}, timeout: 120, on_event: nil)
        envd_client.rpc(service, method, body: body, timeout: timeout, on_event: on_event)
      end

      private

      def build_envd_client
        # The envd URL format: https://{port}-{sandboxId}.{domain}
        # Port comes FIRST, then sandbox ID
        envd_url = "https://#{ENVD_PORT}-#{@sandbox_id}.#{@sandbox_domain}"

        EnvdHttpClient.new(
          base_url: envd_url,
          api_key: @api_key,
          access_token: @access_token,
          sandbox_id: @sandbox_id,
          logger: @logger
        )
      end
    end

    # HTTP client specifically for envd communication
    class EnvdHttpClient
      DEFAULT_TIMEOUT = 120

      def initialize(base_url:, api_key:, access_token: nil, sandbox_id:, logger: nil)
        @base_url = base_url.end_with?("/") ? base_url : "#{base_url}/"
        @api_key = api_key
        @access_token = access_token
        @sandbox_id = sandbox_id
        @logger = logger
        @connection = build_connection

        # Debug logging
        if defined?(Rails)
          Rails.logger.info "[E2B::EnvdHttpClient] Initialized with base_url: #{@base_url}, access_token present: #{@access_token.present?}"
        end
      end

      def get(path, params: {}, timeout: DEFAULT_TIMEOUT)
        handle_response do
          @connection.get(normalize_path(path)) do |req|
            req.params = params
            req.options.timeout = timeout
          end
        end
      end

      def post(path, body: nil, timeout: DEFAULT_TIMEOUT)
        handle_response do
          @connection.post(normalize_path(path)) do |req|
            req.body = body.to_json if body
            req.options.timeout = timeout
          end
        end
      end

      def delete(path, timeout: DEFAULT_TIMEOUT)
        handle_response do
          @connection.delete(normalize_path(path)) do |req|
            req.options.timeout = timeout
          end
        end
      end

      # Connect RPC call with streaming support
      #
      # @param service [String] Service name (e.g., "process.Process")
      # @param method [String] Method name (e.g., "Start")
      # @param body [Hash] Request body
      # @param timeout [Integer] Request timeout in seconds
      # @param on_event [Proc, nil] Callback for each streamed event
      # @return [Hash] Response
      def rpc(service, method, body: {}, timeout: DEFAULT_TIMEOUT, on_event: nil)
        # Connect RPC path format: /package.Service/Method
        path = "/#{service}/#{method}"

        # Debug logging
        full_url = "#{@base_url}#{path}"
        if defined?(Rails)
          Rails.logger.info "[E2B::RPC] Calling #{full_url}"
          Rails.logger.debug "[E2B::RPC] Body: #{body.inspect}"
        end

        # Connect RPC requires envelope format: 1 byte flags + 4 bytes length (big-endian) + JSON message
        url = URI.parse("#{@base_url.chomp('/')}#{path}")

        Rails.logger.info "[E2B::RPC] Full URL: #{url}" if defined?(Rails)

        # Create envelope
        json_body = body.to_json
        envelope = create_connect_envelope(json_body)

        # Streaming mode if callback provided
        if on_event
          return handle_streaming_rpc(url, envelope, timeout, on_event)
        end

        handle_rpc_response(service, method) do
          # Retry logic for transient SSL/network errors
          max_retries = 3
          retry_count = 0
          last_error = nil

          begin
            http = Net::HTTP.new(url.host, url.port)
            http.use_ssl = true
            http.open_timeout = 30
            http.read_timeout = timeout

            # Keep-alive settings to prevent premature connection closure
            http.keep_alive_timeout = 30

            # Respect E2B_SSL_VERIFY environment variable
            ssl_verify = ENV.fetch("E2B_SSL_VERIFY", "true").downcase != "false"
            http.verify_mode = ssl_verify ? OpenSSL::SSL::VERIFY_PEER : OpenSSL::SSL::VERIFY_NONE

            # SSL options to handle connection issues
            http.ssl_version = :TLSv1_2

            request = Net::HTTP::Post.new(url.request_uri)
            request["Content-Type"] = "application/connect+json"
            request["X-Access-Token"] = @access_token if @access_token
            request["Connection"] = "keep-alive"
            request.body = envelope

            # Debug logging
            if defined?(Rails)
              Rails.logger.info "[E2B::RPC] >>> Request URL: #{url}"
              Rails.logger.info "[E2B::RPC] >>> Request URI: #{url.request_uri}"
              Rails.logger.info "[E2B::RPC] >>> Host: #{url.host}, Port: #{url.port}"
              Rails.logger.info "[E2B::RPC] >>> Body JSON: #{json_body}"
              Rails.logger.info "[E2B::RPC] >>> Access Token present: #{@access_token.present?}"
            end

            response = http.request(request)

            # Debug response
            if defined?(Rails)
              Rails.logger.info "[E2B::RPC] <<< Response status: #{response.code}"
              Rails.logger.info "[E2B::RPC] <<< Response body: #{response.body.to_s.truncate(500)}"
            end

            OpenStruct.new(
              status: response.code.to_i,
              success?: response.code.to_i >= 200 && response.code.to_i < 300,
              body: response.body,
              headers: response.to_hash
            )
          rescue OpenSSL::SSL::SSLError, Errno::ECONNRESET, EOFError, Net::OpenTimeout, Net::ReadTimeout => e
            last_error = e
            retry_count += 1

            if retry_count <= max_retries
              sleep_time = 2 ** retry_count # Exponential backoff: 2, 4, 8 seconds
              Rails.logger.warn "[E2B::RPC] SSL/Network error (attempt #{retry_count}/#{max_retries}): #{e.message}. Retrying in #{sleep_time}s..." if defined?(Rails)
              sleep(sleep_time)
              retry
            else
              Rails.logger.error "[E2B::RPC] SSL/Network error after #{max_retries} retries: #{e.message}" if defined?(Rails)
              raise E2B::E2BError, "Connection failed after #{max_retries} retries: #{e.message}"
            end
          end
        end
      end

      # Handle streaming RPC with chunked response processing
      #
      # This reads the HTTP response body incrementally and calls the callback
      # for each message as it arrives, enabling real-time streaming.
      #
      # @param url [URI] Request URL
      # @param envelope [String] Connect RPC envelope body
      # @param timeout [Integer] Request timeout
      # @param on_event [Proc] Callback for each streamed event
      # @return [Hash] Final accumulated result
      def handle_streaming_rpc(url, envelope, timeout, on_event)
        max_retries = 3
        retry_count = 0
        result = { events: [], stdout: "", stderr: "", exit_code: nil }
        buffer = "".b  # Binary buffer for Connect envelope parsing

        begin
          http = Net::HTTP.new(url.host, url.port)
          http.use_ssl = true
          http.open_timeout = 30
          http.read_timeout = timeout
          http.keep_alive_timeout = 30

          ssl_verify = ENV.fetch("E2B_SSL_VERIFY", "true").downcase != "false"
          http.verify_mode = ssl_verify ? OpenSSL::SSL::VERIFY_PEER : OpenSSL::SSL::VERIFY_NONE
          http.ssl_version = :TLSv1_2

          request = Net::HTTP::Post.new(url.request_uri)
          request["Content-Type"] = "application/connect+json"
          request["X-Access-Token"] = @access_token if @access_token
          request["Connection"] = "keep-alive"
          request.body = envelope

          Rails.logger.info "[E2B::RPC Streaming] Starting streaming request to #{url}" if defined?(Rails)

          http.start do |conn|
            conn.request(request) do |response|
              unless response.code.to_i >= 200 && response.code.to_i < 300
                body = response.body
                handle_error(OpenStruct.new(status: response.code.to_i, success?: false, body: body, headers: response.to_hash))
              end

              # Read response body in chunks
              response.read_body do |chunk|
                next if chunk.nil? || chunk.empty?

                buffer << chunk

                # Try to parse messages from buffer
                # Connect protocol: [1 byte flags][4 bytes big-endian length][message bytes]
                while buffer.bytesize >= 5
                  flags = buffer.getbyte(0)
                  length = buffer.byteslice(1, 4).unpack1("N")

                  break if length.nil? || buffer.bytesize < 5 + length

                  # Extract message
                  message_bytes = buffer.byteslice(5, length)
                  buffer = buffer.byteslice(5 + length..-1) || "".b

                  next if message_bytes.nil? || message_bytes.empty?

                  message_str = message_bytes.force_encoding("UTF-8")

                  begin
                    msg = JSON.parse(message_str)

                    # Handle Connect RPC envelope
                    msg = msg["result"] if msg["result"]

                    result[:events] << msg

                    # Extract stdout/stderr from process events
                    stdout_data = nil
                    stderr_data = nil

                    if msg["event"]
                      event = msg["event"]

                      # Handle Data event
                      data_event = event["Data"] || event["data"]
                      if data_event
                        stdout_data = decode_base64(data_event["stdout"]) if data_event["stdout"]
                        stderr_data = decode_base64(data_event["stderr"]) if data_event["stderr"]
                        result[:stdout] += stdout_data if stdout_data
                        result[:stderr] += stderr_data if stderr_data
                      end

                      # Handle End event
                      end_event = event["End"] || event["end"]
                      if end_event
                        exit_value = end_event["exitCode"] || end_event["exit_code"] || end_event["status"]
                        result[:exit_code] = parse_exit_code(exit_value)
                      end
                    end

                    # Handle direct stdout/stderr fields
                    if msg["stdout"]
                      stdout_data = decode_base64(msg["stdout"])
                      result[:stdout] += stdout_data
                    end
                    if msg["stderr"]
                      stderr_data = decode_base64(msg["stderr"])
                      result[:stderr] += stderr_data
                    end
                    if msg["exitCode"] || msg["exit_code"]
                      result[:exit_code] = parse_exit_code(msg["exitCode"] || msg["exit_code"])
                    end

                    # Call the streaming callback with the new data
                    on_event.call(
                      stdout: stdout_data,
                      stderr: stderr_data,
                      exit_code: result[:exit_code],
                      event: msg
                    )
                  rescue JSON::ParserError => e
                    Rails.logger.warn "[E2B::RPC Streaming] Failed to parse message: #{e.message}" if defined?(Rails)
                  end
                end
              end
            end
          end

          Rails.logger.info "[E2B::RPC Streaming] Completed - stdout: #{result[:stdout].length} bytes, exit_code: #{result[:exit_code]}" if defined?(Rails)

          result
        rescue OpenSSL::SSL::SSLError, Errno::ECONNRESET, EOFError, Net::OpenTimeout, Net::ReadTimeout => e
          retry_count += 1

          if retry_count <= max_retries
            sleep_time = 2 ** retry_count
            Rails.logger.warn "[E2B::RPC Streaming] SSL/Network error (attempt #{retry_count}/#{max_retries}): #{e.message}. Retrying in #{sleep_time}s..." if defined?(Rails)
            sleep(sleep_time)
            retry
          else
            Rails.logger.error "[E2B::RPC Streaming] SSL/Network error after #{max_retries} retries: #{e.message}" if defined?(Rails)
            raise E2B::E2BError, "Connection failed after #{max_retries} retries: #{e.message}"
          end
        end
      end

      private

      def normalize_path(path)
        path.to_s.sub(%r{^/+}, "")
      end

      def build_connection
        ssl_verify = ENV.fetch("E2B_SSL_VERIFY", "true").downcase != "false"

        Faraday.new(url: @base_url, ssl: { verify: ssl_verify }) do |conn|
          conn.request :json
          conn.response :json, content_type: /\bjson$/
          conn.adapter Faraday.default_adapter

          # E2B sandbox-specific headers (required for routing)
          conn.headers["E2b-Sandbox-Id"] = @sandbox_id
          conn.headers["E2b-Sandbox-Port"] = "#{BaseService::ENVD_PORT}"

          # E2B authentication headers
          conn.headers["X-API-Key"] = @api_key
          conn.headers["X-Access-Token"] = @access_token if @access_token

          # Standard headers for Connect RPC with JSON
          conn.headers["Content-Type"] = "application/json"
          conn.headers["Accept"] = "application/json"
          conn.headers["User-Agent"] = "e2b-ruby-sdk/#{E2B::VERSION}"
        end
      end

      def handle_response
        response = yield
        handle_error(response) unless response.success?

        body = response.body

        if body.is_a?(String) && !body.empty?
          content_type = response.headers["content-type"] rescue "unknown"
          if content_type&.include?("json") || body.start_with?("{", "[")
            begin
              return JSON.parse(body)
            rescue JSON::ParserError
              # Return as-is
            end
          end
        end

        body
      rescue Faraday::TimeoutError => e
        raise E2B::TimeoutError, "Request timed out: #{e.message}"
      rescue Faraday::ConnectionFailed => e
        raise E2B::E2BError, "Connection to sandbox failed: #{e.message}"
      end

      # Handle Connect RPC response (may be streaming with binary envelopes)
      def handle_rpc_response(service, method)
        response = yield

        handle_error(response) unless response.success?

        body = response.body
        return {} if body.nil? || body.empty?

        # Debug: Log raw response info
        if defined?(Rails)
          Rails.logger.info "[E2B::RPC] Response status: #{response.status}"
          Rails.logger.info "[E2B::RPC] Response body length: #{body.bytesize}"
          Rails.logger.info "[E2B::RPC] Response first 20 bytes: #{body.bytes.first(20).inspect}"
          Rails.logger.info "[E2B::RPC] Response body preview: #{body.to_s.encode('UTF-8', invalid: :replace, undef: :replace).truncate(300)}"
        end

        result = { events: [], stdout: "", stderr: "", exit_code: nil }

        # Try to parse Connect envelope format first (binary: 1 byte flags + 4 bytes length + message)
        # Then fall back to NDJSON
        messages = parse_connect_stream(body)

        if defined?(Rails)
          Rails.logger.info "[E2B::RPC] Parsed #{messages.length} messages from response"
        end

        messages.each do |msg_str|
          begin
            msg = JSON.parse(msg_str)

            if defined?(Rails)
              Rails.logger.debug "[E2B::RPC] Parsed message: #{msg.to_json.truncate(200)}"
            end

            # Handle Connect RPC envelope
            msg = msg["result"] if msg["result"]

            result[:events] << msg

            # Extract stdout/stderr from process events
            # E2B envd format: {"event":{"Data":{"stdout":"base64..."}}} or {"event":{"End":{"exitCode":0}}}
            if msg["event"]
              event = msg["event"]

              # Handle Data event (contains stdout/stderr)
              if event["Data"]
                data = event["Data"]
                result[:stdout] += decode_base64(data["stdout"]) if data["stdout"]
                result[:stderr] += decode_base64(data["stderr"]) if data["stderr"]
              elsif event["data"]
                data = event["data"]
                result[:stdout] += decode_base64(data["stdout"]) if data["stdout"]
                result[:stderr] += decode_base64(data["stderr"]) if data["stderr"]
              end

              # Handle End/end event (contains exit code)
              # Format can be: {"end":{"status":"exit status 0"}} or {"End":{"exitCode":0}}
              end_event = event["End"] || event["end"]
              if end_event
                exit_value = end_event["exitCode"] || end_event["exit_code"] || end_event["status"]
                result[:exit_code] = parse_exit_code(exit_value)
              end
            end

            # Handle direct stdout/stderr fields
            result[:stdout] += decode_base64(msg["stdout"]) if msg["stdout"]
            result[:stderr] += decode_base64(msg["stderr"]) if msg["stderr"]
            if msg["exitCode"] || msg["exit_code"]
              result[:exit_code] = parse_exit_code(msg["exitCode"] || msg["exit_code"])
            end
          rescue JSON::ParserError => e
            Rails.logger.warn "[E2B::RPC] Failed to parse message: #{e.message}" if defined?(Rails)
          end
        end

        if defined?(Rails)
          Rails.logger.info "[E2B::RPC] Final result - stdout: #{result[:stdout].length} bytes, stderr: #{result[:stderr].length} bytes, exit_code: #{result[:exit_code]}"
        end

        result
      rescue Faraday::TimeoutError => e
        raise E2B::TimeoutError, "Request timed out: #{e.message}"
      rescue Faraday::ConnectionFailed => e
        raise E2B::E2BError, "Connection to sandbox failed: #{e.message}"
      end

      # Parse Connect streaming response - handles both binary envelope and NDJSON formats
      def parse_connect_stream(body)
        messages = []

        # First, try to parse as binary Connect envelope format
        # Format: [1 byte flags][4 bytes big-endian length][message bytes]...
        if body.bytes.first(1) == [0] && body.bytesize >= 5
          offset = 0
          while offset + 5 <= body.bytesize
            flags = body.getbyte(offset)
            length = body.byteslice(offset + 1, 4).unpack1("N")

            break if length.nil? || offset + 5 + length > body.bytesize

            message = body.byteslice(offset + 5, length)
            messages << message.force_encoding("UTF-8") if message && !message.empty?
            offset += 5 + length
          end

          return messages if messages.any?
        end

        # Fall back to NDJSON parsing (newline-delimited JSON)
        body.each_line do |line|
          line = line.strip
          messages << line unless line.empty?
        end

        # If still no messages, try the whole body as a single JSON
        messages << body if messages.empty? && body.start_with?("{")

        messages
      end

      # Create Connect RPC envelope
      #
      # Connect protocol requires: 1 byte flags + 4 bytes length (big-endian) + message
      #
      # @param json_message [String] JSON message to wrap
      # @return [String] Binary envelope
      def create_connect_envelope(json_message)
        flags = "\x00".b  # 0 = no compression
        length = [ json_message.bytesize ].pack("N")  # big-endian 4 bytes
        flags + length + json_message
      end

      # Parse exit code from various formats
      # Handles: integer 0, string "0", string "exit status 0"
      def parse_exit_code(value)
        return 0 if value.nil?
        return value if value.is_a?(Integer)

        str = value.to_s
        # Handle "exit status N" format
        if str =~ /exit status (\d+)/i
          $1.to_i
        elsif str =~ /^(\d+)$/
          $1.to_i
        else
          # Non-zero exit if we can't parse
          str.include?("0") ? 0 : 1
        end
      end

      def decode_base64(data)
        return "" if data.nil? || data.empty?

        Base64.decode64(data)
      rescue
        data.to_s
      end

      def handle_error(response)
        message = extract_error_message(response)
        status = response.status
        headers = response.headers.to_h

        case status
        when 401, 403
          raise E2B::AuthenticationError.new(message, status_code: status, headers: headers)
        when 404
          raise E2B::NotFoundError.new(message, status_code: status, headers: headers)
        when 429
          raise E2B::RateLimitError.new(message, status_code: status, headers: headers)
        else
          raise E2B::E2BError.new(message, status_code: status, headers: headers)
        end
      end

      def extract_error_message(response)
        body = response.body
        return body["message"] if body.is_a?(Hash) && body["message"]
        return body["error"] if body.is_a?(Hash) && body["error"]
        return body.to_s if body.is_a?(String) && !body.empty?

        "HTTP #{response.status} error"
      end
    end
  end
end
