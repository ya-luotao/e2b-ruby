# frozen_string_literal: true

require "shellwords"
require "base64"

module E2B
  module Services
    # Command execution service for E2B sandbox
    #
    # Provides methods to run terminal commands inside the sandbox.
    # Uses Connect RPC protocol to communicate with the envd process service.
    #
    # @example Basic usage
    #   result = sandbox.commands.run("ls -la")
    #   puts result.stdout
    #
    # @example With streaming callbacks
    #   sandbox.commands.run("npm install",
    #     on_stdout: ->(data) { print data },
    #     on_stderr: ->(data) { warn data }
    #   )
    #
    # @example Background command
    #   handle = sandbox.commands.run("sleep 10", background: true)
    #   handle.kill
    class Commands < BaseService
      # Run a command in the sandbox
      #
      # @param cmd [String] Command to execute (run via /bin/bash -l -c)
      # @param background [Boolean] Run in background, returns CommandHandle
      # @param envs [Hash{String => String}, nil] Environment variables
      # @param user [String, nil] User to run the command as
      # @param cwd [String, nil] Working directory
      # @param on_stdout [Proc, nil] Callback for stdout data
      # @param on_stderr [Proc, nil] Callback for stderr data
      # @param timeout [Integer] Command timeout in seconds (default: 60)
      # @param request_timeout [Integer, nil] HTTP request timeout in seconds
      # @return [CommandResult, CommandHandle] Result or handle for background commands
      #
      # @raise [CommandExitError] If exit code is non-zero (foreground only)
      def run(cmd, background: false, envs: nil, user: nil, cwd: nil,
              on_stdout: nil, on_stderr: nil, timeout: 60, request_timeout: nil, &block)
        # Build the process spec - official SDK always uses /bin/bash -l -c
        process_spec = {
          cmd: "/bin/bash",
          args: ["-l", "-c", cmd.to_s]
        }

        if envs && !envs.empty?
          env_map = {}
          envs.each { |k, v| env_map[k.to_s] = v.to_s }
          process_spec[:envs] = env_map
        end

        process_spec[:cwd] = cwd if cwd

        body = { process: process_spec }

        # Set up streaming callback
        streaming_callback = nil
        if on_stdout || on_stderr || block_given?
          streaming_callback = lambda { |event_data|
            stdout_chunk = event_data[:stdout]
            stderr_chunk = event_data[:stderr]

            on_stdout&.call(stdout_chunk) if stdout_chunk && !stdout_chunk.empty?
            on_stderr&.call(stderr_chunk) if stderr_chunk && !stderr_chunk.empty?

            if block_given?
              yield(:stdout, stdout_chunk) if stdout_chunk && !stdout_chunk.empty?
              yield(:stderr, stderr_chunk) if stderr_chunk && !stderr_chunk.empty?
            end
          }
        end

        effective_timeout = request_timeout || (timeout + 30)

        response = envd_rpc("process.Process", "Start",
          body: body,
          timeout: effective_timeout,
          on_event: streaming_callback)

        pid = extract_pid(response)

        if background
          # Return a CommandHandle for background processes
          CommandHandle.new(
            pid: pid,
            handle_kill: -> { kill(pid) },
            handle_send_stdin: ->(data) { send_stdin(pid, data) },
            result: response
          )
        else
          # Return CommandResult for foreground processes
          result = build_result(response)

          # Raise on non-zero exit code (matching official SDK behavior)
          if result.exit_code != 0
            raise CommandExitError.new(
              stdout: result.stdout,
              stderr: result.stderr,
              exit_code: result.exit_code,
              error: result.error
            )
          end

          result
        end
      end

      # List running processes
      #
      # @param request_timeout [Integer, nil] Request timeout in seconds
      # @return [Array<Hash>] List of running processes with pid, config, tag
      def list(request_timeout: nil)
        response = envd_rpc("process.Process", "List",
          body: {},
          timeout: request_timeout || 30)

        processes = []
        events = response[:events] || []
        events.each do |event|
          next unless event.is_a?(Hash)
          if event["processes"]
            processes.concat(Array(event["processes"]))
          end
        end
        processes
      end

      # Kill a running process
      #
      # @param pid [Integer] Process ID to kill
      # @param request_timeout [Integer, nil] Request timeout in seconds
      # @return [Boolean] true if killed, false if not found
      def kill(pid, request_timeout: nil)
        envd_rpc("process.Process", "SendSignal",
          body: {
            process: { pid: pid },
            signal: 9 # SIGKILL
          },
          timeout: request_timeout || 30)
        true
      rescue E2B::NotFoundError
        false
      rescue E2B::E2BError
        false
      end

      # Send stdin data to a running process
      #
      # @param pid [Integer] Process ID
      # @param data [String] Data to send to stdin
      # @param request_timeout [Integer, nil] Request timeout in seconds
      def send_stdin(pid, data, request_timeout: nil)
        encoded = Base64.strict_encode64(data.to_s)
        envd_rpc("process.Process", "SendInput",
          body: {
            process: { pid: pid },
            input: { stdin: encoded }
          },
          timeout: request_timeout || 30)
      end

      # Connect to a running process
      #
      # @param pid [Integer] Process ID to connect to
      # @param timeout [Integer] Connection timeout in seconds
      # @param request_timeout [Integer, nil] Request timeout in seconds
      # @return [CommandHandle] Handle for the connected process
      def connect(pid, timeout: 60, request_timeout: nil)
        response = envd_rpc("process.Process", "Connect",
          body: { process: { pid: pid } },
          timeout: request_timeout || (timeout + 30))

        CommandHandle.new(
          pid: pid,
          handle_kill: -> { kill(pid) },
          handle_send_stdin: ->(data) { send_stdin(pid, data) },
          result: response
        )
      end

      private

      # Extract PID from streaming response events
      def extract_pid(response)
        events = response[:events] || []
        events.each do |event|
          next unless event.is_a?(Hash) && event["event"]
          start_event = event["event"]["Start"] || event["event"]["start"]
          if start_event && start_event["pid"]
            return start_event["pid"].to_i
          end
        end
        nil
      end

      # Build CommandResult from response
      def build_result(response)
        stdout = response[:stdout] || ""
        stderr = response[:stderr] || ""
        exit_code = response[:exit_code]
        error = nil

        # Parse exit code
        exit_code = exit_code.to_i if exit_code.is_a?(String) && exit_code.match?(/^\d+$/)
        exit_code ||= 0

        # Check events for error info
        events = response[:events] || []
        events.each do |event|
          next unless event.is_a?(Hash) && event["event"]
          end_event = event["event"]["End"] || event["event"]["end"]
          if end_event
            error = end_event["error"] if end_event["error"] && !end_event["error"].empty?
          end
        end

        CommandResult.new(
          stdout: stdout,
          stderr: stderr,
          exit_code: exit_code,
          error: error
        )
      end
    end
  end
end
