# frozen_string_literal: true

require "base64"
require "net/http"
require "openssl"
require "ostruct"
require "rubygems/version"

module E2B
  module Services
    # Base class for sandbox services
    #
    # E2B sandboxes expose services through the envd daemon on port 49983.
    # This base class handles communication with that daemon using the
    # Connect RPC protocol (gRPC-over-HTTP with JSON encoding).
    class BaseService
      # Default envd port
      ENVD_PORT = 49983
      DEFAULT_USERNAME = "user"
      ENVD_DEFAULT_USER_VERSION = Gem::Version.new("0.4.0")
      ENVD_RECURSIVE_WATCH_VERSION = Gem::Version.new("0.1.4")

      # @param sandbox_id [String] Sandbox ID
      # @param sandbox_domain [String] Sandbox domain (e.g., "e2b.app")
      # @param api_key [String] API key for authentication
      # @param access_token [String, nil] Sandbox-specific access token
      # @param logger [Logger, nil] Optional logger
      def initialize(sandbox_id:, sandbox_domain:, api_key:, access_token: nil, envd_version: nil, logger: nil)
        @sandbox_id = sandbox_id
        @sandbox_domain = sandbox_domain
        @api_key = api_key
        @access_token = access_token
        @envd_version = envd_version
        @logger = logger
        @envd_client = nil
      end

      protected

      # Get the envd HTTP client for this sandbox
      #
      # @return [EnvdHttpClient]
      def envd_client
        @envd_client ||= build_envd_client
      end

      # Perform GET request to envd
      def envd_get(path, params: {}, timeout: 120, headers: nil)
        envd_client.get(path, params: params, timeout: timeout, headers: headers)
      end

      # Perform POST request to envd
      def envd_post(path, body: nil, timeout: 120, headers: nil)
        envd_client.post(path, body: body, timeout: timeout, headers: headers)
      end

      # Perform DELETE request to envd
      def envd_delete(path, timeout: 120, headers: nil)
        envd_client.delete(path, timeout: timeout, headers: headers)
      end

      # Perform Connect RPC call to envd
      #
      # @param service [String] Service name (e.g., "process.Process")
      # @param method [String] Method name (e.g., "Start")
      # @param body [Hash] Request body
      # @param timeout [Integer] Request timeout in seconds
      # @param on_event [Proc, nil] Callback for streaming events
      # @return [Hash] Response with :events, :stdout, :stderr, :exit_code
      def envd_rpc(service, method, body: {}, timeout: 120, on_event: nil, headers: nil)
        envd_client.rpc(service, method, body: body, timeout: timeout, on_event: on_event, headers: headers)
      end

      def user_auth_headers(user)
        resolved_user = resolve_username(user)
        return nil if resolved_user.nil? || resolved_user.to_s.empty?

        encoded = Base64.strict_encode64("#{resolved_user}:")
        { "Authorization" => "Basic #{encoded}" }
      end

      def resolve_username(user)
        return user unless user.nil? || user.to_s.empty?
        return DEFAULT_USERNAME if legacy_default_user?

        nil
      end

      def legacy_default_user?
        return false if @envd_version.nil? || @envd_version.to_s.empty?

        Gem::Version.new(@envd_version) < ENVD_DEFAULT_USER_VERSION
      rescue ArgumentError
        false
      end

      def supports_recursive_watch?
        return true if @envd_version.nil? || @envd_version.to_s.empty?

        Gem::Version.new(@envd_version) >= ENVD_RECURSIVE_WATCH_VERSION
      rescue ArgumentError
        true
      end

      private

      def build_envd_client
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

    # HTTP client for envd daemon communication
    #
    # Handles both standard HTTP requests and Connect RPC protocol calls.
    # Connect RPC uses a binary envelope format: 1 byte flags + 4 bytes
    # big-endian length + JSON message body.
    class EnvdHttpClient
      DEFAULT_TIMEOUT = 120

      def initialize(base_url:, api_key:, access_token: nil, sandbox_id:, logger: nil)
        @base_url = base_url.end_with?("/") ? base_url : "#{base_url}/"
        @api_key = api_key
        @access_token = access_token
        @sandbox_id = sandbox_id
        @logger = logger
        @connection = build_connection
      end

      def get(path, params: {}, timeout: DEFAULT_TIMEOUT, headers: nil)
        handle_response do
          @connection.get(normalize_path(path)) do |req|
            req.params = params
            req.options.timeout = timeout
            req.headers.update(headers) if headers
          end
        end
      end

      def post(path, body: nil, timeout: DEFAULT_TIMEOUT, headers: nil)
        handle_response do
          @connection.post(normalize_path(path)) do |req|
            req.body = body.to_json if body
            req.options.timeout = timeout
            req.headers.update(headers) if headers
          end
        end
      end

      def delete(path, timeout: DEFAULT_TIMEOUT, headers: nil)
        handle_response do
          @connection.delete(normalize_path(path)) do |req|
            req.options.timeout = timeout
            req.headers.update(headers) if headers
          end
        end
      end

      # Connect RPC call with streaming support
      #
      # @param service [String] Service name
      # @param method [String] Method name
      # @param body [Hash] Request body
      # @param timeout [Integer] Timeout in seconds
      # @param on_event [Proc, nil] Callback for streaming events
      # @return [Hash] Response
      def rpc(service, method, body: {}, timeout: DEFAULT_TIMEOUT, on_event: nil, headers: nil)
        path = "/#{service}/#{method}"
        json_body = body.to_json
        envelope = create_connect_envelope(json_body)

        log_debug("RPC #{service}/#{method}")

        if on_event
          return handle_streaming_rpc(path, envelope, timeout, on_event, headers)
        end

        handle_rpc_response(service, method, headers: headers) do
          with_retry("RPC #{service}/#{method}") do
            url = URI.parse("#{@base_url.chomp('/')}#{path}")
            http = build_http(url, timeout)

            request = Net::HTTP::Post.new(url.request_uri)
            request["Content-Type"] = "application/connect+json"
            request["X-Access-Token"] = @access_token if @access_token
            request["Connection"] = "keep-alive"
            apply_custom_headers(request, headers)
            request.body = envelope

            response = http.request(request)

            OpenStruct.new(
              status: response.code.to_i,
              success?: response.code.to_i >= 200 && response.code.to_i < 300,
              body: response.body,
              headers: response.to_hash
            )
          end
        end
      end

      # Streaming RPC with chunked response processing
      def handle_streaming_rpc(path, envelope, timeout, on_event, headers)
        result = { events: [], stdout: "", stderr: "", exit_code: nil }
        buffer = "".b

        url = URI.parse("#{@base_url.chomp('/')}#{path}")

        with_retry("Streaming RPC #{path}") do
          http = build_http(url, timeout)

          request = Net::HTTP::Post.new(url.request_uri)
          request["Content-Type"] = "application/connect+json"
          request["X-Access-Token"] = @access_token if @access_token
          request["Connection"] = "keep-alive"
          apply_custom_headers(request, headers)
          request.body = envelope

          http.start do |conn|
            conn.request(request) do |response|
              unless response.code.to_i.between?(200, 299)
                body = response.body
                handle_error(OpenStruct.new(status: response.code.to_i, success?: false, body: body, headers: response.to_hash))
              end

              response.read_body do |chunk|
                next if chunk.nil? || chunk.empty?
                buffer << chunk

                while buffer.bytesize >= 5
                  flags = buffer.getbyte(0)
                  length = buffer.byteslice(1, 4).unpack1("N")

                  break if length.nil? || buffer.bytesize < 5 + length

                  message_bytes = buffer.byteslice(5, length)
                  buffer = buffer.byteslice(5 + length..-1) || "".b

                  next if message_bytes.nil? || message_bytes.empty?

                  message_str = message_bytes.force_encoding("UTF-8")

                  begin
                    msg = JSON.parse(message_str)
                    msg = msg["result"] if msg["result"]

                    result[:events] << msg

                    stdout_data = nil
                    stderr_data = nil

                    if msg["event"]
                      event = msg["event"]

                      data_event = event["Data"] || event["data"]
                      if data_event
                        stdout_data = decode_base64(data_event["stdout"]) if data_event["stdout"]
                        stderr_data = decode_base64(data_event["stderr"]) if data_event["stderr"]
                        result[:stdout] += stdout_data if stdout_data
                        result[:stderr] += stderr_data if stderr_data
                      end

                      end_event = event["End"] || event["end"]
                      if end_event
                        result[:exit_code] = parse_exit_code(end_event["exitCode"] || end_event["exit_code"] || end_event["status"])
                      end
                    end

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

                    on_event.call(
                      stdout: stdout_data,
                      stderr: stderr_data,
                      exit_code: result[:exit_code],
                      event: msg
                    )
                  rescue JSON::ParserError
                    # Skip unparseable messages
                  end
                end
              end
            end
          end
        end

        result
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

          conn.headers["E2b-Sandbox-Id"] = @sandbox_id
          conn.headers["E2b-Sandbox-Port"] = "#{BaseService::ENVD_PORT}"
          conn.headers["X-API-Key"] = @api_key
          conn.headers["X-Access-Token"] = @access_token if @access_token
          conn.headers["Content-Type"] = "application/json"
          conn.headers["Accept"] = "application/json"
          conn.headers["User-Agent"] = "e2b-ruby-sdk/#{E2B::VERSION}"
        end
      end

      def build_http(url, timeout)
        http = Net::HTTP.new(url.host, url.port)
        http.use_ssl = true
        http.open_timeout = 30
        http.read_timeout = timeout
        http.keep_alive_timeout = 30

        ssl_verify = ENV.fetch("E2B_SSL_VERIFY", "true").downcase != "false"
        http.verify_mode = ssl_verify ? OpenSSL::SSL::VERIFY_PEER : OpenSSL::SSL::VERIFY_NONE

        http
      end

      def with_retry(operation, max_retries: 3)
        retry_count = 0

        begin
          yield
        rescue OpenSSL::SSL::SSLError, Errno::ECONNRESET, EOFError, Net::OpenTimeout, Net::ReadTimeout => e
          retry_count += 1

          if retry_count <= max_retries
            sleep_time = 2**retry_count
            log_debug("#{operation}: retry #{retry_count}/#{max_retries} after #{e.class}: #{e.message}")
            sleep(sleep_time)
            retry
          else
            raise E2B::E2BError, "#{operation} failed after #{max_retries} retries: #{e.message}"
          end
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

      def handle_rpc_response(service, method, headers: nil)
        response = yield

        handle_error(response) unless response.success?

        body = response.body
        return {} if body.nil? || body.empty?

        result = { events: [], stdout: "", stderr: "", exit_code: nil }

        messages = parse_connect_stream(body)

        messages.each do |msg_str|
          begin
            msg = JSON.parse(msg_str)
            msg = msg["result"] if msg["result"]

            result[:events] << msg

            if msg["event"]
              event = msg["event"]

              data_event = event["Data"] || event["data"]
              if data_event
                result[:stdout] += decode_base64(data_event["stdout"]) if data_event["stdout"]
                result[:stderr] += decode_base64(data_event["stderr"]) if data_event["stderr"]
              end

              end_event = event["End"] || event["end"]
              if end_event
                exit_value = end_event["exitCode"] || end_event["exit_code"] || end_event["status"]
                result[:exit_code] = parse_exit_code(exit_value)
              end
            end

            result[:stdout] += decode_base64(msg["stdout"]) if msg["stdout"]
            result[:stderr] += decode_base64(msg["stderr"]) if msg["stderr"]
            if msg["exitCode"] || msg["exit_code"]
              result[:exit_code] = parse_exit_code(msg["exitCode"] || msg["exit_code"])
            end
          rescue JSON::ParserError
            # Skip unparseable messages
          end
        end

        result
      rescue Faraday::TimeoutError => e
        raise E2B::TimeoutError, "Request timed out: #{e.message}"
      rescue Faraday::ConnectionFailed => e
        raise E2B::E2BError, "Connection to sandbox failed: #{e.message}"
      end

      def parse_connect_stream(body)
        messages = []

        # Try binary Connect envelope format first
        if body.bytes.first(1) == [0] && body.bytesize >= 5
          offset = 0
          while offset + 5 <= body.bytesize
            length = body.byteslice(offset + 1, 4).unpack1("N")
            break if length.nil? || offset + 5 + length > body.bytesize

            message = body.byteslice(offset + 5, length)
            messages << message.force_encoding("UTF-8") if message && !message.empty?
            offset += 5 + length
          end

          return messages if messages.any?
        end

        # Fall back to NDJSON
        body.each_line do |line|
          line = line.strip
          messages << line unless line.empty?
        end

        messages << body if messages.empty? && body.start_with?("{")

        messages
      end

      def create_connect_envelope(json_message)
        flags = "\x00".b
        length = [json_message.bytesize].pack("N")
        flags + length + json_message
      end

      def parse_exit_code(value)
        return 0 if value.nil?
        return value if value.is_a?(Integer)

        str = value.to_s
        if str =~ /exit status (\d+)/i
          $1.to_i
        elsif str =~ /^(\d+)$/
          $1.to_i
        else
          str.include?("0") ? 0 : 1
        end
      end

      def decode_base64(data)
        return "" if data.nil? || data.empty?

        Base64.decode64(data)
      rescue StandardError
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

      def log_debug(message)
        @logger&.debug("[E2B] #{message}")
      end

      def apply_custom_headers(request, headers)
        return unless headers

        headers.each do |key, value|
          request[key] = value
        end
      end
    end
  end
end
