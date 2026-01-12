# frozen_string_literal: true

require "base64"
require "net/http"
require "openssl"
require "shellwords"
require "uri"

module E2B
  module Services
    # Filesystem operations for E2B sandbox
    #
    # Provides methods for reading, writing, and managing files in the sandbox.
    # Uses shell commands via the process service and REST endpoints for file transfer.
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
      DEFAULT_USER = "user"

      # Read file content using REST endpoint
      #
      # @param path [String] File path in the sandbox
      # @param user [String] Username context (unused, kept for API compatibility)
      # @return [String] File content
      #
      # @example
      #   content = sandbox.files.read("/home/user/config.json")
      def read(path, user: DEFAULT_USER)
        url = build_file_url("/files/download", path: path)
        response = rest_get(url)

        # Response is raw file content
        response
      end

      # Maximum file size that can be written (10MB)
      # Prevents accidental memory exhaustion from large file operations
      MAX_WRITE_SIZE = 10_485_760

      # Write content to a file using shell commands
      #
      # @param path [String] File path in the sandbox
      # @param content [String] Content to write
      # @param user [String] Username context (unused, kept for API compatibility)
      #
      # @raise [E2B::E2BError] If content exceeds MAX_WRITE_SIZE or write fails
      #
      # @example
      #   sandbox.files.write("/home/user/output.txt", "Hello, World!")
      def write(path, content, user: DEFAULT_USER)
        content_size = content.bytesize
        if content_size > MAX_WRITE_SIZE
          raise E2B::E2BError, "File content too large: #{content_size} bytes exceeds #{MAX_WRITE_SIZE} byte limit"
        end

        # Ensure parent directory exists
        dir = File.dirname(path)
        mkdir(dir) unless dir == "." || dir == "/"

        # Use base64 encoding with heredoc for safe content transfer through shell
        # Heredoc with quoted delimiter ('E2B_EOF') prevents any shell interpretation
        encoded = Base64.strict_encode64(content)
        escaped_path = Shellwords.escape(path)

        # Use heredoc for safer content transfer (avoids single-quote issues)
        result = run_command(<<~BASH)
          base64 -d << 'E2B_EOF' > #{escaped_path}
          #{encoded}
          E2B_EOF
        BASH

        raise E2B::E2BError, "Failed to write file: #{result[:stderr]}" unless result[:success]
      end

      # Write multiple files at once
      #
      # @param files [Array<Hash>] Array of { path:, content: } hashes
      # @param user [String] Username context
      #
      # @example
      #   sandbox.files.write_multiple([
      #     { path: "/home/user/a.txt", content: "Content A" },
      #     { path: "/home/user/b.txt", content: "Content B" }
      #   ])
      def write_multiple(files, user: DEFAULT_USER)
        files.each do |file|
          write(file[:path], file[:content], user: user)
        end
      end

      # List directory contents using shell command
      #
      # @param path [String] Directory path
      # @param user [String] Username context
      # @return [Array<Hash>] List of entries with name, type, size, etc.
      #
      # @example
      #   entries = sandbox.files.list("/home/user")
      #   entries.each { |e| puts "#{e['name']} (#{e['type']})" }
      def list(path, user: DEFAULT_USER)
        # Use ls -la to get detailed listing
        result = run_command("ls -la #{Shellwords.escape(path)}")
        return [] unless result[:success]

        # Parse ls output into entries
        parse_ls_output(result[:stdout])
      end

      # Check if a path exists
      #
      # @param path [String] Path to check
      # @param user [String] Username context
      # @return [Boolean]
      def exists?(path, user: DEFAULT_USER)
        result = run_command("test -e #{Shellwords.escape(path)} && echo 'exists'")
        result[:stdout].include?("exists")
      end

      # Get file/directory information
      #
      # @param path [String] Path to get info for
      # @param user [String] Username context
      # @return [Hash] File info (size, type, permissions, etc.)
      def info(path, user: DEFAULT_USER)
        result = run_command("stat -c '%s %Y %a %U %G' #{Shellwords.escape(path)} 2>/dev/null || stat -f '%z %m %p %Su %Sg' #{Shellwords.escape(path)}")
        return {} unless result[:success]

        parts = result[:stdout].strip.split
        {
          "size" => parts[0].to_i,
          "mtime" => parts[1].to_i,
          "mode" => parts[2],
          "owner" => parts[3],
          "group" => parts[4]
        }
      end

      # Create a directory
      #
      # @param path [String] Directory path to create
      # @param user [String] Username context
      def mkdir(path, user: DEFAULT_USER)
        result = run_command("mkdir -p #{Shellwords.escape(path)}")
        raise E2B::E2BError, "Failed to create directory: #{result[:stderr]}" unless result[:success]
      end

      # Delete a file or directory
      #
      # @param path [String] Path to delete
      # @param user [String] Username context
      def remove(path, user: DEFAULT_USER)
        result = run_command("rm -rf #{Shellwords.escape(path)}")
        raise E2B::E2BError, "Failed to remove: #{result[:stderr]}" unless result[:success]
      end

      # Move/rename a file or directory
      #
      # @param source [String] Source path
      # @param destination [String] Destination path
      # @param user [String] Username context
      def move(source, destination, user: DEFAULT_USER)
        result = run_command("mv #{Shellwords.escape(source)} #{Shellwords.escape(destination)}")
        raise E2B::E2BError, "Failed to move: #{result[:stderr]}" unless result[:success]
      end

      # Copy a file or directory
      #
      # @param source [String] Source path
      # @param destination [String] Destination path
      # @param user [String] Username context
      def copy(source, destination, user: DEFAULT_USER)
        result = run_command("cp -r #{Shellwords.escape(source)} #{Shellwords.escape(destination)}")
        raise E2B::E2BError, "Failed to copy: #{result[:stderr]}" unless result[:success]
      end

      # Watch a directory for changes
      #
      # @param path [String] Directory path to watch
      # @param user [String] Username context
      # @yield [event] Block called for each file change event
      # @yieldparam event [Hash] Event with type, path, etc.
      def watch(path, user: DEFAULT_USER, &block)
        # This would require WebSocket support for real-time watching
        # For now, this is a placeholder
        raise NotImplementedError, "Directory watching requires WebSocket support"
      end

      # Alias methods for compatibility with Daytona SDK
      alias read_file read
      alias write_file write
      alias list_files list
      alias create_folder mkdir
      alias delete_file remove
      alias move_files move

      private

      # Run a shell command using the process RPC
      def run_command(command)
        # Note: Don't set wait:true - it may prevent stdout from being streamed
        response = envd_rpc("process.Process", "Start", body: {
          process: {
            cmd: "/bin/bash",
            args: [ "-c", command ]
          }
        }, timeout: 60)

        exit_code = response[:exit_code]
        exit_code = exit_code.to_i if exit_code.is_a?(String)
        exit_code ||= 0

        {
          success: exit_code.zero?,
          stdout: response[:stdout] || "",
          stderr: response[:stderr] || "",
          exit_code: exit_code
        }
      end

      # Build URL for file operations
      def build_file_url(endpoint, path: nil)
        base = "https://#{ENVD_PORT}-#{@sandbox_id}.#{@sandbox_domain}"
        url = "#{base}#{endpoint}"
        url += "?path=#{URI.encode_www_form_component(path)}" if path
        url
      end

      # Perform REST GET request with retry logic
      def rest_get(url_string)
        with_ssl_retry("GET #{url_string}") do
          uri = URI.parse(url_string)
          request = Net::HTTP::Get.new(uri.request_uri)
          apply_request_headers(request)

          response = execute_http_request(uri, request)
          raise E2B::E2BError, "File read failed: HTTP #{response.code}" unless successful_response?(response)

          response.body
        end
      end

      # Perform REST POST request with retry logic
      def rest_post(url_string, body)
        with_ssl_retry("POST #{url_string}") do
          uri = URI.parse(url_string)
          request = Net::HTTP::Post.new(uri.request_uri)
          request["Content-Type"] = "application/octet-stream"
          request.body = body
          apply_request_headers(request)

          response = execute_http_request(uri, request)
          raise E2B::E2BError, "File write failed: HTTP #{response.code}" unless successful_response?(response)

          true
        end
      end

      def execute_http_request(uri, request)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = true
        http.open_timeout = 30
        http.read_timeout = 120
        http.keep_alive_timeout = 30
        http.ssl_version = :TLSv1_2
        http.verify_mode = ssl_verify_mode
        http.request(request)
      end

      def apply_request_headers(request)
        request["X-Access-Token"] = @access_token if @access_token
        request["Connection"] = "keep-alive"
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
            sleep_time = 2 ** retry_count # Exponential backoff: 2, 4, 8 seconds
            Rails.logger.warn "[E2B::Filesystem] SSL/Network error on #{operation} (attempt #{retry_count}/#{max_retries}): #{e.message}. Retrying in #{sleep_time}s..." if defined?(Rails)
            sleep(sleep_time)
            retry
          else
            Rails.logger.error "[E2B::Filesystem] SSL/Network error after #{max_retries} retries: #{e.message}" if defined?(Rails)
            raise E2B::E2BError, "#{operation} failed after #{max_retries} retries: #{e.message}"
          end
        end
      end

      # Parse ls -la output into structured entries
      def parse_ls_output(output)
        lines = output.lines.drop(1) # Skip "total" line
        lines.filter_map do |line|
          parts = line.split
          next if parts.length < 9

          name = parts[8..].join(" ")
          next if name == "." || name == ".."

          {
            "name" => name,
            "type" => parts[0].start_with?("d") ? "directory" : "file",
            "size" => parts[4].to_i,
            "permissions" => parts[0],
            "owner" => parts[2],
            "group" => parts[3]
          }
        end
      end
    end
  end
end
