# frozen_string_literal: true

require "shellwords"

module E2B
  module Services
    # Command execution service for E2B sandbox
    #
    # Provides methods to run terminal commands inside the sandbox.
    # Uses Connect RPC protocol with JSON encoding.
    #
    # @example
    #   result = sandbox.commands.run("ls -la")
    #   puts result.stdout
    #
    #   # With streaming
    #   sandbox.commands.run("npm install") do |type, data|
    #     puts data if type == :stdout
    #   end
    class Commands < BaseService
      # Run a command in the sandbox
      #
      # @param command [String] Command to execute
      # @param cwd [String, nil] Working directory
      # @param envs [Hash{String => String}, nil] Environment variables
      # @param timeout [Integer] Command timeout in seconds
      # @param background [Boolean] Run in background
      # @param on_stdout [Proc, nil] Callback for stdout data
      # @param on_stderr [Proc, nil] Callback for stderr data
      # @yield [type, data] Optional block for streaming output
      # @return [Models::ProcessResult] Execution result
      #
      # @example Basic usage
      #   result = sandbox.commands.run("echo 'Hello'")
      #   puts result.stdout  # => "Hello\n"
      #
      # @example With callbacks
      #   result = sandbox.commands.run("npm test",
      #     on_stdout: ->(data) { puts data },
      #     on_stderr: ->(data) { warn data }
      #   )
      def run(command, cwd: nil, envs: nil, timeout: 300, background: false,
              on_stdout: nil, on_stderr: nil, &block)
        # Parse command into executable and arguments
        # Handle shell commands by using /bin/bash -c
        cmd_parts = command.to_s.strip
        if cmd_parts.include?(" ") && !cmd_parts.start_with?("/")
          # Complex command - use shell
          executable = "/bin/bash"
          args = [ "-c", cmd_parts ]
        else
          # Simple command or absolute path
          parts = Shellwords.split(cmd_parts)
          executable = parts.first
          args = parts[1..] || []
        end

        # Connect RPC request body for process.Process/Start
        # Proto structure: { process: { cmd, args, envs, cwd }, wait }
        process_spec = {
          cmd: executable,
          args: args
        }

        # E2B envd expects envs as a simple object/map, NOT an array of {name, value}
        # Format: {"KEY": "value", ...}
        if envs && !envs.empty?
          env_map = {}
          envs.each { |k, v| env_map[k.to_s] = v.to_s }
          process_spec[:envs] = env_map
        end

        process_spec[:cwd] = cwd if cwd

        # Note: Don't set wait:true as it may affect stdout streaming
        # The streaming response will wait for process completion anyway
        body = {
          process: process_spec
        }
        body[:timeout] = timeout * 1000 if timeout # Convert to ms

        # If streaming callbacks provided, use streaming RPC
        streaming_callback = nil
        if on_stdout || on_stderr || block_given?
          streaming_callback = ->(event_data) {
            stdout_chunk = event_data[:stdout]
            stderr_chunk = event_data[:stderr]

            # Call stdout callback for each chunk as it arrives
            on_stdout&.call(stdout_chunk) if stdout_chunk && !stdout_chunk.empty?
            on_stderr&.call(stderr_chunk) if stderr_chunk && !stderr_chunk.empty?

            if block_given?
              yield(:stdout, stdout_chunk) if stdout_chunk && !stdout_chunk.empty?
              yield(:stderr, stderr_chunk) if stderr_chunk && !stderr_chunk.empty?
            end
          }
        end

        # Use Connect RPC endpoint: /process.Process/Start
        response = envd_rpc("process.Process", "Start", body: body, timeout: timeout + 30, on_event: streaming_callback)

        # Debug logging
        if defined?(Rails)
          Rails.logger.info "[E2B::Commands] Raw response keys: #{response.keys.inspect}" if response.is_a?(Hash)
          Rails.logger.info "[E2B::Commands] Response stdout length: #{response[:stdout]&.length || 0}"
          Rails.logger.info "[E2B::Commands] Response stderr length: #{response[:stderr]&.length || 0}"
          Rails.logger.info "[E2B::Commands] Response exit_code: #{response[:exit_code]}"
        end

        result = Models::ProcessResult.from_connect_response(response)

        # For non-streaming mode (no callbacks), still call callbacks once at end
        # This maintains backward compatibility
        unless streaming_callback
          on_stdout&.call(result.stdout) unless result.stdout.empty?
          on_stderr&.call(result.stderr) unless result.stderr.empty?

          if block_given?
            yield(:stdout, result.stdout) unless result.stdout.empty?
            yield(:stderr, result.stderr) unless result.stderr.empty?
          end
        end

        result
      end

      # Run a command in the background
      #
      # @param command [String] Command to execute
      # @param cwd [String, nil] Working directory
      # @param envs [Hash{String => String}, nil] Environment variables
      # @return [String] Process ID for the background command
      def start(command, cwd: nil, envs: nil)
        result = run(command, cwd: cwd, envs: envs, background: true)
        # Background commands return a process ID
        result
      end

      # Kill a running process
      #
      # @param pid [String] Process ID to kill
      # @param signal [Integer] Signal to send (default: SIGKILL = 9)
      def kill(pid, signal: 9)
        body = {
          process: { pid: pid },
          signal: signal
        }
        envd_rpc("process.Process", "SendSignal", body: body)
      end

      # List running processes
      #
      # @return [Array<Hash>] List of running processes
      def list
        response = envd_rpc("process.Process", "List", body: {})
        response["processes"] || response[:processes] || []
      end
    end
  end
end
