# frozen_string_literal: true

module E2B
  module Models
    # Result of a process execution
    class ProcessResult
      # @return [String] Standard output
      attr_reader :stdout

      # @return [String] Standard error
      attr_reader :stderr

      # @return [Integer] Exit code
      attr_reader :exit_code

      # @return [String, nil] Error message if any
      attr_reader :error

      # Create from API response hash
      #
      # @param data [Hash] API response data
      # @return [ProcessResult]
      def self.from_hash(data)
        new(
          stdout: data["stdout"] || data[:stdout] || "",
          stderr: data["stderr"] || data[:stderr] || "",
          exit_code: data["exitCode"] || data["exit_code"] || data[:exitCode] || 0,
          error: data["error"] || data[:error]
        )
      end

      # Create from Connect RPC response
      #
      # Connect RPC responses for process.Process/Start contain:
      # - events: Array of streaming events
      # - stdout: Accumulated stdout
      # - stderr: Accumulated stderr
      # - exit_code: Process exit code
      #
      # @param data [Hash] Connect RPC response data
      # @return [ProcessResult]
      def self.from_connect_response(data)
        return from_hash(data) unless data.is_a?(Hash)

        stdout = data[:stdout] || data["stdout"] || ""
        stderr = data[:stderr] || data["stderr"] || ""
        exit_code = data[:exit_code] || data["exit_code"] || data["exitCode"] || 0
        error = data[:error] || data["error"]

        # If no stdout but we have events, try to extract from events
        if stdout.empty? && data[:events].is_a?(Array)
          data[:events].each do |event|
            next unless event.is_a?(Hash)

            # Handle nested event structure
            if event["event"]
              ev = event["event"]
              if ev["Stdout"]
                stdout += decode_base64_safe(ev["Stdout"]["data"])
              elsif ev["stdout"]
                stdout += decode_base64_safe(ev["stdout"]["data"])
              elsif ev["Stderr"]
                stderr += decode_base64_safe(ev["Stderr"]["data"])
              elsif ev["stderr"]
                stderr += decode_base64_safe(ev["stderr"]["data"])
              elsif ev["Exit"]
                exit_code = ev["Exit"]["exitCode"] || ev["Exit"]["exit_code"] || exit_code
              elsif ev["exit"]
                exit_code = ev["exit"]["exitCode"] || ev["exit"]["exit_code"] || exit_code
              end
            end
          end
        end

        new(stdout: stdout, stderr: stderr, exit_code: parse_exit_code(exit_code), error: error)
      end

      def self.decode_base64_safe(data)
        return "" if data.nil? || data.empty?

        Base64.decode64(data)
      rescue
        data.to_s
      end

      # Parse exit code from various formats
      # Handles: integer 0, string "0", string "exit status 0"
      def self.parse_exit_code(value)
        return 0 if value.nil?
        return value if value.is_a?(Integer)

        str = value.to_s
        if str =~ /exit status (\d+)/i
          $1.to_i
        elsif str =~ /(\d+)/
          $1.to_i
        else
          str.include?("0") ? 0 : 1
        end
      end

      def initialize(stdout: "", stderr: "", exit_code: 0, error: nil)
        @stdout = stdout
        @stderr = stderr
        @exit_code = exit_code
        @error = error
      end

      # Check if the process succeeded
      #
      # @return [Boolean]
      def success?
        @exit_code.zero? && @error.nil?
      end

      # Combined output (stdout + stderr)
      #
      # @return [String]
      def output
        "#{@stdout}#{@stderr}"
      end

      # Alias for compatibility with Daytona
      alias result stdout
    end
  end
end
