# frozen_string_literal: true

require "faraday"
require "faraday/multipart"
require "json"

module E2B
  module API
    # HTTP client wrapper for E2B API communication
    #
    # Handles authentication, request/response processing, and error handling.
    class HttpClient
      # Default request timeout in seconds
      DEFAULT_TIMEOUT = 120

      # @return [String] Base URL for API requests
      attr_reader :base_url

      # Initialize a new HTTP client
      #
      # @param base_url [String] Base URL for API requests
      # @param api_key [String] API key for authentication
      # @param logger [Logger, nil] Optional logger
      def initialize(base_url:, api_key:, logger: nil)
        @base_url = base_url.end_with?("/") ? base_url : "#{base_url}/"
        @api_key = api_key
        @logger = logger
        @connection = build_connection
      end

      # Perform a GET request
      #
      # @param path [String] API endpoint path
      # @param params [Hash] Query parameters
      # @param timeout [Integer] Request timeout in seconds
      # @return [Hash, Array, String] Parsed response body
      def get(path, params: {}, timeout: DEFAULT_TIMEOUT)
        handle_response do
          @connection.get(normalize_path(path)) do |req|
            req.params = params
            req.options.timeout = timeout
          end
        end
      end

      # Perform a POST request
      #
      # @param path [String] API endpoint path
      # @param body [Hash, nil] Request body
      # @param timeout [Integer] Request timeout in seconds
      # @return [Hash, Array, String] Parsed response body
      def post(path, body: nil, timeout: DEFAULT_TIMEOUT)
        handle_response do
          @connection.post(normalize_path(path)) do |req|
            req.body = body.to_json if body
            req.options.timeout = timeout
          end
        end
      end

      # Perform a PUT request
      #
      # @param path [String] API endpoint path
      # @param body [Hash, nil] Request body
      # @param timeout [Integer] Request timeout in seconds
      # @return [Hash, Array, String] Parsed response body
      def put(path, body: nil, timeout: DEFAULT_TIMEOUT)
        handle_response do
          @connection.put(normalize_path(path)) do |req|
            req.body = body.to_json if body
            req.options.timeout = timeout
          end
        end
      end

      # Perform a DELETE request
      #
      # @param path [String] API endpoint path
      # @param timeout [Integer] Request timeout in seconds
      # @return [Hash, Array, String, nil] Parsed response body
      def delete(path, timeout: DEFAULT_TIMEOUT)
        handle_response do
          @connection.delete(normalize_path(path)) do |req|
            req.options.timeout = timeout
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

          conn.headers["X-API-Key"] = @api_key
          conn.headers["Content-Type"] = "application/json"
          conn.headers["Accept"] = "application/json"
          conn.headers["User-Agent"] = "e2b-ruby-sdk/#{E2B::VERSION}"
        end
      end

      def handle_response
        response = yield
        handle_error(response) unless response.success?

        body = response.body

        # If body is a string but should be JSON, try to parse it
        if body.is_a?(String) && !body.empty?
          content_type = response.headers["content-type"] rescue "unknown"
          if content_type&.include?("json") || body.start_with?("{", "[")
            begin
              return JSON.parse(body)
            rescue JSON::ParserError
              # Return as-is if can't parse
            end
          end
        end

        body
      rescue Faraday::TimeoutError => e
        raise E2B::TimeoutError, "Request timed out: #{e.message}"
      rescue Faraday::ConnectionFailed => e
        raise E2B::E2BError, "Connection failed: #{e.message}"
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
        when 409
          raise E2B::ConflictError.new(message, status_code: status, headers: headers)
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
