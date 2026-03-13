# frozen_string_literal: true

require "base64"
require "net/http"
require "openssl"
require "uri"
require "json"
require "stringio"

module E2B
  module Services
    # Filesystem operations for E2B sandbox
    #
    # Provides methods for reading, writing, and managing files in the sandbox.
    # Uses envd RPC for filesystem operations and REST endpoints for file transfer.
    #
    # @example
    #   # Write a file
    #   sandbox.files.write("/home/user/hello.txt", "Hello, World!")
    #
    #   # Read a file
    #   content = sandbox.files.read("/home/user/hello.txt")
    #
    #   # List directory
    #   entries = sandbox.files.list("/home/user")
    class Filesystem < BaseService
      # Default username for file operations
      # Read file content
      #
      # @param path [String] File path in the sandbox
      # @param format [String] Return format: "text" (default), "bytes", or "stream"
      # @param user [String] Username context for the operation
      # @param request_timeout [Integer] Request timeout in seconds
      # @return [String] File content
      #
      # @example
      #   content = sandbox.files.read("/home/user/config.json")
      def read(path, format: "text", user: nil, request_timeout: 120)
        url = build_file_url("/files", path: path, user: user)
        response = rest_get(url, timeout: request_timeout)

        case format
        when "text"
          response.dup.force_encoding("UTF-8")
        when "bytes"
          response.b
        when "stream"
          StringIO.new(response.b)
        else
          raise ArgumentError, "Unsupported read format '#{format}'"
        end
      end

      # Write content to a file using REST upload
      #
      # @param path [String] File path in the sandbox
      # @param data [String, IO] Content to write (string or IO object)
      # @param user [String] Username context for the operation
      # @param request_timeout [Integer] Request timeout in seconds
      # @return [Models::WriteInfo] Info about the written file
      #
      # @example
      #   sandbox.files.write("/home/user/output.txt", "Hello, World!")
      def write(path, data, user: nil, request_timeout: 120)
        url = build_file_url("/files", path: path, user: user)
        content = data.is_a?(IO) || data.respond_to?(:read) ? data.read : data.to_s
        result = rest_upload(url, content, timeout: request_timeout)
        build_write_info(result, default_path: path)
      end

      # Write multiple files at once
      #
      # @param files [Array<Hash>] Array of { path:, data: } hashes
      # @param user [String] Username context
      # @param request_timeout [Integer] Request timeout in seconds
      # @return [Array] Results for each file
      #
      # @example
      #   sandbox.files.write_files([
      #     { path: "/home/user/a.txt", data: "Content A" },
      #     { path: "/home/user/b.txt", data: "Content B" }
      #   ])
      def write_files(files, user: nil, request_timeout: 120)
        files.map do |file|
          write(file[:path], file[:data] || file[:content], user: user, request_timeout: request_timeout)
        end
      end

      # List directory contents using filesystem RPC
      #
      # @param path [String] Directory path
      # @param depth [Integer] Recursion depth (default: 1, only immediate children)
      # @param user [String] Username context
      # @param request_timeout [Integer] Request timeout in seconds
      # @return [Array<Models::EntryInfo>] List of entries
      #
      # @example
      #   entries = sandbox.files.list("/home/user")
      #   entries.each { |e| puts "#{e.name} (#{e.type})" }
      def list(path, depth: 1, user: nil, request_timeout: 60)
        response = envd_rpc("filesystem.Filesystem", "ListDir",
          body: { path: path, depth: depth },
          timeout: request_timeout,
          headers: user_auth_headers(user))

        entries = extract_entries(response)
        entries.map { |e| Models::EntryInfo.from_hash(e) }
      end

      # Check if a path exists
      #
      # @param path [String] Path to check
      # @param user [String] Username context
      # @param request_timeout [Integer] Request timeout in seconds
      # @return [Boolean]
      def exists?(path, user: nil, request_timeout: 30)
        get_info(path, user: user, request_timeout: request_timeout)
        true
      rescue E2B::NotFoundError, E2B::E2BError
        false
      end

      # Get file/directory information using filesystem RPC
      #
      # @param path [String] Path to get info for
      # @param user [String] Username context
      # @param request_timeout [Integer] Request timeout in seconds
      # @return [Models::EntryInfo] File/directory info
      def get_info(path, user: nil, request_timeout: 30)
        response = envd_rpc("filesystem.Filesystem", "Stat",
          body: { path: path },
          timeout: request_timeout,
          headers: user_auth_headers(user))

        entry_data = extract_entry(response)
        Models::EntryInfo.from_hash(entry_data)
      end

      # Remove a file or directory
      #
      # @param path [String] Path to remove
      # @param user [String] Username context
      # @param request_timeout [Integer] Request timeout in seconds
      def remove(path, user: nil, request_timeout: 30)
        envd_rpc("filesystem.Filesystem", "Remove",
          body: { path: path },
          timeout: request_timeout,
          headers: user_auth_headers(user))
      end

      # Rename/move a file or directory
      #
      # @param old_path [String] Source path
      # @param new_path [String] Destination path
      # @param user [String] Username context
      # @param request_timeout [Integer] Request timeout in seconds
      # @return [Models::EntryInfo] Info about the moved entry
      def rename(old_path, new_path, user: nil, request_timeout: 30)
        response = envd_rpc("filesystem.Filesystem", "Move",
          body: { source: old_path, destination: new_path },
          timeout: request_timeout,
          headers: user_auth_headers(user))

        entry_data = extract_entry(response)
        Models::EntryInfo.from_hash(entry_data)
      end

      # Create a directory
      #
      # @param path [String] Directory path to create
      # @param user [String] Username context
      # @param request_timeout [Integer] Request timeout in seconds
      # @return [Boolean] true if created successfully
      def make_dir(path, user: nil, request_timeout: 30)
        envd_rpc("filesystem.Filesystem", "MakeDir",
          body: { path: path },
          timeout: request_timeout,
          headers: user_auth_headers(user))
        true
      end

      # Watch a directory for filesystem changes
      #
      # Uses the polling-based CreateWatcher/GetWatcherEvents/RemoveWatcher RPCs.
      #
      # @param path [String] Directory path to watch
      # @param recursive [Boolean] Watch subdirectories recursively
      # @param user [String] Username context
      # @param request_timeout [Integer] Request timeout in seconds
      # @return [WatchHandle] Handle for polling events and stopping the watcher
      #
      # @example
      #   handle = sandbox.files.watch_dir("/home/user/project")
      #   # ... wait for changes ...
      #   events = handle.get_new_events
      #   events.each { |e| puts "#{e.type}: #{e.name}" }
      #   handle.stop
      def watch_dir(path, recursive: false, user: nil, request_timeout: 30)
        if recursive && !supports_recursive_watch?
          raise E2B::TemplateError,
            "You need to update the template to use recursive watching. You can do this by running `e2b template build` in the directory with the template."
        end

        response = envd_rpc("filesystem.Filesystem", "CreateWatcher",
          body: { path: path, recursive: recursive },
          timeout: request_timeout,
          headers: user_auth_headers(user))

        watcher_id = response[:events]&.first&.dig("watcherId") ||
                     response["watcherId"] ||
                     extract_watcher_id(response)

        raise E2B::E2BError, "Failed to create watcher: no watcher_id returned" unless watcher_id

        rpc_proc = method(:envd_rpc)
        WatchHandle.new(
          watcher_id: watcher_id,
          envd_rpc_proc: rpc_proc,
          headers: user_auth_headers(user)
        )
      end

      # Backward-compatible aliases
      alias read_file read
      alias write_file write
      alias list_files list
      alias mkdir make_dir
      alias move rename
      alias create_folder make_dir
      alias delete_file remove
      alias move_files rename

      private

      # Build URL for file operations
      def build_file_url(endpoint, path: nil, user: nil)
        user = resolve_username(user)
        base = "https://#{ENVD_PORT}-#{@sandbox_id}.#{@sandbox_domain}"
        url = "#{base}#{endpoint}"
        params = []
        params << "path=#{URI.encode_www_form_component(path)}" if path
        params << "username=#{URI.encode_www_form_component(user)}" if user
        url += "?#{params.join("&")}" unless params.empty?
        url
      end

      # Perform REST GET request for file download
      def rest_get(url_string, timeout: 120)
        with_ssl_retry("GET #{url_string}") do
          uri = URI.parse(url_string)
          request = Net::HTTP::Get.new(uri.request_uri)
          apply_request_headers(request)

          response = execute_http_request(uri, request, timeout: timeout)
          unless successful_response?(response)
            if response.code.to_i == 404
              raise E2B::NotFoundError.new("File not found", status_code: 404)
            end
            raise E2B::E2BError, "File read failed: HTTP #{response.code}"
          end

          response.body
        end
      end

      # Perform REST POST for file upload (multipart form data)
      def rest_upload(url_string, content, timeout: 120)
        with_ssl_retry("POST #{url_string}") do
          uri = URI.parse(url_string)

          boundary = "----E2BRubySDK#{SecureRandom.hex(16)}"
          body = build_multipart_body(boundary, content)

          request = Net::HTTP::Post.new(uri.request_uri)
          request["Content-Type"] = "multipart/form-data; boundary=#{boundary}"
          request.body = body
          apply_request_headers(request)

          response = execute_http_request(uri, request, timeout: timeout)
          unless successful_response?(response)
            raise E2B::E2BError, "File upload failed: HTTP #{response.code}"
          end

          parse_upload_response(response.body)
        end
      end

      def build_multipart_body(boundary, content)
        body = "".b
        body << "--#{boundary}\r\n"
        body << "Content-Disposition: form-data; name=\"file\"; filename=\"upload\"\r\n"
        body << "Content-Type: application/octet-stream\r\n"
        body << "\r\n"
        body << content.b
        body << "\r\n"
        body << "--#{boundary}--\r\n"
        body
      end

      def execute_http_request(uri, request, timeout: 120)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = true
        http.open_timeout = 30
        http.read_timeout = timeout
        http.keep_alive_timeout = 30
        http.verify_mode = ssl_verify_mode
        http.request(request)
      end

      def apply_request_headers(request)
        request["X-Access-Token"] = @access_token if @access_token
        request["Connection"] = "keep-alive"
        request["User-Agent"] = "e2b-ruby-sdk/#{E2B::VERSION}"
      end

      def parse_upload_response(body)
        return [] if body.nil? || body.empty?

        JSON.parse(body)
      rescue JSON::ParserError
        []
      end

      def ssl_verify_mode
        ssl_verify = ENV.fetch("E2B_SSL_VERIFY", "true").downcase != "false"
        ssl_verify ? OpenSSL::SSL::VERIFY_PEER : OpenSSL::SSL::VERIFY_NONE
      end

      def successful_response?(response)
        code = response.code.to_i
        code >= 200 && code < 300
      end

      # Retry wrapper for SSL/network errors
      def with_ssl_retry(operation, max_retries: 3)
        retry_count = 0

        begin
          yield
        rescue OpenSSL::SSL::SSLError, Errno::ECONNRESET, EOFError, Net::OpenTimeout, Net::ReadTimeout => e
          retry_count += 1

          if retry_count <= max_retries
            sleep_time = 2**retry_count
            sleep(sleep_time)
            retry
          else
            raise E2B::E2BError, "#{operation} failed after #{max_retries} retries: #{e.message}"
          end
        end
      end

      # Extract entries from RPC response
      def extract_entries(response)
        return [] unless response.is_a?(Hash)

        # The response comes through the Connect envelope parser
        # Check various possible locations for the entries array
        events = response[:events] || []
        entries = []

        events.each do |event|
          next unless event.is_a?(Hash)
          # Direct entries field
          if event["entries"]
            entries.concat(Array(event["entries"]))
          elsif event["result"] && event["result"]["entries"]
            entries.concat(Array(event["result"]["entries"]))
          end
        end

        # Also check top-level
        entries = response["entries"] || [] if entries.empty?
        entries
      end

      # Extract single entry from RPC response
      def extract_entry(response)
        return {} unless response.is_a?(Hash)

        events = response[:events] || []
        events.each do |event|
          next unless event.is_a?(Hash)
          return event["entry"] if event["entry"]
          return event["result"]["entry"] if event.dig("result", "entry")
        end

        response["entry"] || {}
      end

      # Extract watcher_id from CreateWatcher response
      def extract_watcher_id(response)
        return nil unless response.is_a?(Hash)

        events = response[:events] || []
        events.each do |event|
          next unless event.is_a?(Hash)
          return event["watcherId"] || event["watcher_id"] if event["watcherId"] || event["watcher_id"]
          result = event["result"]
          return result["watcherId"] || result["watcher_id"] if result.is_a?(Hash) && (result["watcherId"] || result["watcher_id"])
        end

        nil
      end

      def build_write_info(result, default_path:)
        case result
        when Array
          entry = result.first
          return build_write_info(entry, default_path: default_path) if entry
        when Hash
          path = result["path"] || result[:path] || default_path
          return Models::WriteInfo.new(path: path)
        end

        Models::WriteInfo.new(path: default_path)
      end
    end
  end
end
