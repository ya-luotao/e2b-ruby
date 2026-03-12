# frozen_string_literal: true

require "base64"

module E2B
  module Services
    # Result of a command execution in the sandbox.
    #
    # Returned by {CommandHandle#wait} when the command finishes successfully.
    #
    # @example
    #   result = handle.wait
    #   puts result.stdout
    #   puts result.exit_code  # => 0
    class CommandResult
      # @return [String] Standard output accumulated from the command
      attr_reader :stdout

      # @return [String] Standard error accumulated from the command
      attr_reader :stderr

      # @return [Integer] Exit code of the command (0 indicates success)
      attr_reader :exit_code

      # @return [String, nil] Error message from command execution, if any
      attr_reader :error

      # @param stdout [String] Standard output
      # @param stderr [String] Standard error
      # @param exit_code [Integer] Exit code
      # @param error [String, nil] Error message
      def initialize(stdout: "", stderr: "", exit_code: 0, error: nil)
        @stdout = stdout
        @stderr = stderr
        @exit_code = exit_code
        @error = error
      end

      # Check if the command finished successfully.
      #
      # @return [Boolean] true if exit code is 0 and no error is present
      def success?
        @exit_code == 0 && @error.nil?
      end

      # Combined output (stdout + stderr).
      #
      # @return [String]
      def output
        "#{@stdout}#{@stderr}"
      end

      # @return [String]
      def to_s
        "#<#{self.class.name} exit_code=#{@exit_code} stdout=#{@stdout.bytesize}B stderr=#{@stderr.bytesize}B>"
      end

      alias inspect to_s
    end

    # Handle for an executing command in the sandbox.
    #
    # Provides methods for waiting on the command, sending stdin input,
    # killing the process, disconnecting from the event stream, and
    # iterating over stdout/stderr/pty output as it arrives.
    #
    # Instances are returned by {Commands#run} (background mode),
    # {Pty#create}, and {Pty#connect}.
    #
    # @example Wait for a command and get output
    #   handle = sandbox.pty.create
    #   result = handle.wait(on_pty: ->(data) { print data })
    #
    # @example Iterate over output
    #   handle.each do |stdout, stderr, pty|
    #     print stdout if stdout
    #   end
    #
    # @example Kill a long-running process
    #   handle.kill
    class CommandHandle
      include Enumerable

      # @return [Integer, nil] Process ID of the running command
      attr_reader :pid

      # Initialize a new CommandHandle.
      #
      # Callers should not construct this directly; it is created by service
      # methods such as {Pty#create} or {Commands#run}.
      #
      # @param pid [Integer, nil] Process ID
      # @param handle_kill [Proc] Proc that sends SIGKILL to the process
      # @param handle_send_stdin [Proc] Proc that sends data to stdin/pty
      # @param events_proc [Proc, nil] Proc that accepts a block and yields
      #   parsed events as they arrive. Each event is a Hash with keys like
      #   "event" => { "Start" => ..., "Data" => ..., "End" => ... }.
      #   May be nil if the result is already materialized.
      # @param result [Hash, nil] Pre-materialized result from a synchronous
      #   RPC call. Expected keys: :events, :stdout, :stderr, :exit_code.
      def initialize(pid:, handle_kill:, handle_send_stdin:, events_proc: nil, result: nil)
        @pid = pid
        @handle_kill = handle_kill
        @handle_send_stdin = handle_send_stdin
        @events_proc = events_proc
        @result = result
        @disconnected = false
        @finished = false
        @stdout = ""
        @stderr = ""
        @exit_code = nil
        @error = nil
        @mutex = Mutex.new
      end

      # Wait for the command to finish and return the result.
      #
      # If the command exits with a non-zero exit code, raises
      # {CommandExitError}. Callbacks are invoked as output
      # arrives (or immediately if the result is already materialized).
      #
      # @param on_stdout [Proc, nil] Called with each chunk of stdout (String)
      # @param on_stderr [Proc, nil] Called with each chunk of stderr (String)
      # @param on_pty [Proc, nil] Called with each chunk of PTY output (String)
      # @return [CommandResult]
      # @raise [CommandExitError] if exit code is non-zero
      def wait(on_stdout: nil, on_stderr: nil, on_pty: nil)
        consume_events(on_stdout: on_stdout, on_stderr: on_stderr, on_pty: on_pty)
        build_result.tap do |cmd_result|
          unless cmd_result.success?
            raise CommandExitError.new(
              stdout: cmd_result.stdout,
              stderr: cmd_result.stderr,
              exit_code: cmd_result.exit_code,
              error: cmd_result.error
            )
          end
        end
      end

      # Kill the running command with SIGKILL.
      #
      # @return [Boolean] true if the signal was sent successfully, false on error
      def kill
        @handle_kill.call
      end

      # Send data to the command's stdin (or PTY input).
      #
      # @param data [String] Data to write
      # @return [void]
      def send_stdin(data)
        @handle_send_stdin.call(data)
      end

      # Disconnect from the command event stream without killing the process.
      #
      # After disconnecting, {#wait} and {#each} will return immediately
      # with whatever output has been accumulated so far. The underlying
      # process continues running and can be reconnected to via
      # {Commands#connect} or {Pty#connect}.
      #
      # @return [void]
      def disconnect
        @disconnected = true
      end

      # Iterate over command output as it arrives.
      #
      # Yields a triple of [stdout, stderr, pty] for each chunk of output.
      # Exactly one of the three will be non-nil per iteration.
      #
      # @yield [stdout, stderr, pty] Output chunks
      # @yieldparam stdout [String, nil] Stdout data, or nil
      # @yieldparam stderr [String, nil] Stderr data, or nil
      # @yieldparam pty [String, nil] PTY data, or nil
      # @return [void]
      def each(&block)
        return enum_for(:each) unless block_given?

        if @result
          # Iterate over pre-materialized events
          iterate_materialized_events(&block)
        elsif @events_proc
          # Iterate over streaming events
          iterate_streaming_events(&block)
        end
      end

      private

      # Consume all remaining events, invoking callbacks along the way.
      #
      # @param on_stdout [Proc, nil]
      # @param on_stderr [Proc, nil]
      # @param on_pty [Proc, nil]
      # @return [void]
      def consume_events(on_stdout: nil, on_stderr: nil, on_pty: nil)
        return if @finished

        each do |stdout_chunk, stderr_chunk, pty_chunk|
          if stdout_chunk
            on_stdout&.call(stdout_chunk)
            @mutex.synchronize { @stdout += stdout_chunk }
          end
          if stderr_chunk
            on_stderr&.call(stderr_chunk)
            @mutex.synchronize { @stderr += stderr_chunk }
          end
          if pty_chunk
            on_pty&.call(pty_chunk)
          end
        end

        @finished = true
      end

      # Build a {CommandResult} from accumulated state.
      #
      # If we have a pre-materialized result and haven't iterated events,
      # use its values directly.
      #
      # @return [CommandResult]
      def build_result
        if @result && !@finished
          # Use the pre-materialized result from the synchronous RPC call
          CommandResult.new(
            stdout: @result[:stdout] || "",
            stderr: @result[:stderr] || "",
            exit_code: @result[:exit_code] || 0,
            error: @result[:error]
          )
        else
          CommandResult.new(
            stdout: @stdout,
            stderr: @stderr,
            exit_code: @exit_code || 0,
            error: @error
          )
        end
      end

      # Iterate over events from a pre-materialized result hash.
      #
      # The result hash is produced by {EnvdHttpClient#handle_streaming_rpc}
      # or {EnvdHttpClient#handle_rpc_response} and contains an :events array
      # with parsed JSON hashes.
      #
      # @yield [stdout, stderr, pty]
      # @return [void]
      def iterate_materialized_events
        events = @result[:events] || []
        events.each do |event_hash|
          break if @disconnected

          next unless event_hash.is_a?(Hash) && event_hash["event"]

          event = event_hash["event"]
          process_event(event) do |stdout_chunk, stderr_chunk, pty_chunk|
            yield stdout_chunk, stderr_chunk, pty_chunk
          end
        end
      end

      # Iterate over events from a streaming proc.
      #
      # The events_proc is called with a block; it yields parsed event
      # hashes as they arrive from the RPC stream.
      #
      # @yield [stdout, stderr, pty]
      # @return [void]
      def iterate_streaming_events
        @events_proc.call do |event_hash|
          break if @disconnected

          next unless event_hash.is_a?(Hash) && event_hash["event"]

          event = event_hash["event"]
          process_event(event) do |stdout_chunk, stderr_chunk, pty_chunk|
            yield stdout_chunk, stderr_chunk, pty_chunk
          end
        end
      end

      # Process a single event from the stream, extracting output data.
      #
      # Event shapes from the envd process service:
      # - Start: { "Start" => { "pid" => 123 } }
      # - Data:  { "Data"  => { "stdout" => "base64", "stderr" => "base64", "pty" => "base64" } }
      # - End:   { "End"   => { "exitCode" => 0, "error" => "...", "status" => "..." } }
      #
      # @param event [Hash] The event sub-hash (value of "event" key)
      # @yield [stdout, stderr, pty]
      # @return [void]
      def process_event(event)
        # Handle Data event
        data_event = event["Data"] || event["data"]
        if data_event
          stdout_chunk = decode_base64(data_event["stdout"])
          stderr_chunk = decode_base64(data_event["stderr"])
          pty_chunk = decode_base64(data_event["pty"])

          yield(stdout_chunk, nil, nil) if stdout_chunk && !stdout_chunk.empty?
          yield(nil, stderr_chunk, nil) if stderr_chunk && !stderr_chunk.empty?
          yield(nil, nil, pty_chunk) if pty_chunk && !pty_chunk.empty?
        end

        # Handle End event
        end_event = event["End"] || event["end"]
        return unless end_event

        exit_value = end_event["exitCode"] || end_event["exit_code"] || end_event["status"]
        @exit_code = parse_exit_code(exit_value)
        @error = end_event["error"] if end_event["error"] && !end_event["error"].empty?
      end

      # Decode a base64-encoded string.
      #
      # @param data [String, nil] Base64-encoded data
      # @return [String, nil] Decoded string, or nil if input is nil/empty
      def decode_base64(data)
        return nil if data.nil? || data.empty?

        Base64.decode64(data).force_encoding("UTF-8")
      rescue StandardError
        data.to_s
      end

      # Parse an exit code from various envd response formats.
      #
      # Handles integer values, string integers, and "exit status N" strings.
      #
      # @param value [Integer, String, nil] Raw exit code value
      # @return [Integer]
      def parse_exit_code(value)
        return 0 if value.nil?
        return value if value.is_a?(Integer)

        str = value.to_s
        if str =~ /exit status (\d+)/i
          ::Regexp.last_match(1).to_i
        elsif str =~ /^(\d+)$/
          ::Regexp.last_match(1).to_i
        else
          1
        end
      end
    end
  end
end
