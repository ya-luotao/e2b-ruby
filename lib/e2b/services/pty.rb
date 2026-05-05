# frozen_string_literal: true

require "base64"
require_relative "base_service"
require_relative "command_handle"

module E2B
  module Services
    # Pseudo-terminal size specification.
    #
    # @example Default 80x24 terminal
    #   size = PtySize.new
    #
    # @example Custom size
    #   size = PtySize.new(cols: 120, rows: 40)
    class PtySize
      # @return [Integer] Number of columns
      attr_reader :cols

      # @return [Integer] Number of rows
      attr_reader :rows

      # @param cols [Integer] Number of columns (default: 80)
      # @param rows [Integer] Number of rows (default: 24)
      def initialize(cols: 80, rows: 24)
        @cols = cols
        @rows = rows
      end

      # Convert to a Hash suitable for the Connect RPC request body.
      #
      # @return [Hash]
      def to_h
        { cols: @cols, rows: @rows }
      end
    end

    # PTY (pseudo-terminal) service for E2B sandbox.
    #
    # Provides methods to create, connect to, and manage interactive
    # pseudo-terminals inside the sandbox. Uses Connect RPC protocol
    # with the +process.Process+ service.
    #
    # @example Create a PTY and send commands
    #   pty = sandbox.pty
    #   handle = pty.create
    #   handle.send_stdin("ls -la\n")
    #   result = handle.wait(on_pty: ->(data) { print data })
    #
    # @example Resize a PTY
    #   pty.resize(handle.pid, PtySize.new(cols: 120, rows: 40))
    #
    # @example Connect to an existing PTY
    #   handle = pty.connect(pid)
    class Pty < BaseService
      include LiveStreamable
      # Default shell to use for PTY sessions
      DEFAULT_SHELL = "/bin/bash"

      # Default shell arguments for interactive login shell
      DEFAULT_SHELL_ARGS = ["-i", "-l"].freeze

      # Create a new PTY (pseudo-terminal) session in the sandbox.
      #
      # Starts an interactive shell process with a PTY attached. The
      # returned {CommandHandle} can be used to send input, receive
      # output, and manage the PTY lifecycle.
      #
      # @param size [PtySize] Terminal size (default: 80 columns x 24 rows)
      # @param user [String, nil] User to run the PTY as
      # @param cwd [String, nil] Working directory for the PTY shell
      # @param envs [Hash{String => String}, nil] Environment variables
      # @param cmd [String] Shell executable (default: /bin/bash)
      # @param args [Array<String>] Shell arguments (default: ["-i", "-l"])
      # @param timeout [Integer] Timeout for the PTY session in seconds
      # @return [CommandHandle] Handle to interact with the PTY
      # @raise [E2B::E2BError] if the PTY could not be started
      #
      # @example
      #   handle = sandbox.pty.create(
      #     size: PtySize.new(cols: 120, rows: 40),
      #     cwd: "/home/user/project",
      #     envs: { "EDITOR" => "vim" }
      #   )
      def create(size: PtySize.new, user: nil, cwd: nil, envs: nil,
                 cmd: DEFAULT_SHELL, args: DEFAULT_SHELL_ARGS, timeout: 60)
        envs = build_pty_envs(envs)
        headers = user_auth_headers(user)

        process_spec = {
          cmd: cmd,
          args: args,
          envs: envs
        }
        process_spec[:cwd] = cwd if cwd

        body = {
          process: process_spec,
          pty: {
            size: size.to_h
          },
          stdin: false
        }

        build_live_handle(
          rpc_method: "Start",
          body: body,
          headers: headers,
          timeout: timeout + 30
        )
      end

      # Connect to an existing PTY process.
      #
      # Attaches to a running PTY process by PID and returns a handle
      # for sending input and receiving output.
      #
      # @param pid [Integer] Process ID of the PTY to connect to
      # @param timeout [Integer] Timeout for the connection in seconds
      # @return [CommandHandle] Handle to interact with the PTY
      # @raise [E2B::E2BError] if the process is not found or connection fails
      #
      # @example
      #   handle = sandbox.pty.connect(12345)
      #   handle.send_stdin("whoami\n")
      def connect(pid, timeout: 60)
        body = {
          process: { pid: pid }
        }

        build_live_handle(
          rpc_method: "Connect",
          body: body,
          headers: user_auth_headers(nil),
          timeout: timeout + 30
        )
      end

      # Send input data to a PTY.
      #
      # The data is base64-encoded and sent as PTY input (not stdin),
      # which means it goes through the terminal emulator and supports
      # control characters, escape sequences, etc.
      #
      # @param pid [Integer] Process ID of the PTY
      # @param data [String] Input data to send (e.g., "ls -la\n")
      # @return [void]
      # @raise [E2B::E2BError] if the process is not found
      #
      # @example Send a command
      #   sandbox.pty.send_stdin(pid, "echo hello\n")
      #
      # @example Send Ctrl+C
      #   sandbox.pty.send_stdin(pid, "\x03")
      def send_stdin(pid, data, headers: nil)
        encoded = Base64.strict_encode64(data.is_a?(String) ? data : data.to_s)
        envd_rpc("process.Process", "SendInput", body: {
          process: { pid: pid },
          input: { pty: encoded }
        }, headers: headers)
      end

      # Kill a PTY process with SIGKILL.
      #
      # @param pid [Integer] Process ID of the PTY to kill
      # @return [Boolean] true if the signal was sent, false if the process was not found
      #
      # @example
      #   sandbox.pty.kill(12345)
      def kill(pid, headers: nil)
        envd_rpc("process.Process", "SendSignal", body: {
          process: { pid: pid },
          signal: 9 # SIGKILL
        }, headers: headers)
        true
      rescue E2B::E2BError
        false
      end

      # Resize a PTY terminal.
      #
      # Should be called when the terminal window size changes to keep
      # the remote PTY in sync.
      #
      # @param pid [Integer] Process ID of the PTY
      # @param size [PtySize] New terminal size
      # @return [void]
      # @raise [E2B::E2BError] if the process is not found
      #
      # @example
      #   sandbox.pty.resize(pid, PtySize.new(cols: 120, rows: 40))
      def resize(pid, size)
        envd_rpc("process.Process", "Update", body: {
          process: { pid: pid },
          pty: {
            size: size.to_h
          }
        })
      end

      # Close the stdin of a PTY process.
      #
      # After calling this, no more input can be sent to the PTY via
      # {#send_stdin}.
      #
      # @param pid [Integer] Process ID of the PTY
      # @return [void]
      # @raise [E2B::E2BError] if the process is not found
      def close_stdin(pid)
        envd_rpc("process.Process", "CloseStdin", body: {
          process: { pid: pid }
        })
      end

      # List running processes in the sandbox.
      #
      # @return [Array<Hash>] List of running process descriptors
      def list
        response = envd_rpc("process.Process", "List", body: {})
        response["processes"] || response[:processes] || []
      end

      private

      # Build environment variables hash with PTY defaults.
      #
      # Ensures TERM, LANG, and LC_ALL are set to sensible defaults
      # for terminal operation unless the caller has overridden them.
      #
      # @param envs [Hash{String => String}, nil] Caller-provided env vars
      # @return [Hash{String => String}]
      def build_pty_envs(envs)
        result = {}
        result["TERM"] = "xterm-256color"
        result["LANG"] = "C.UTF-8"
        result["LC_ALL"] = "C.UTF-8"

        if envs.is_a?(Hash)
          envs.each { |k, v| result[k.to_s] = v.to_s }
        end

        result
      end

    end
  end
end
