# frozen_string_literal: true

module E2B
  module Services
    # Shared live-stream handle builder for Commands and Pty.
    #
    # Both services need to start a background thread that runs an envd RPC,
    # extract the PID from the first Start event, and return a CommandHandle
    # wired to a LiveEventStream. This module keeps that logic in one place.
    module LiveStreamable
      private

      def build_live_handle(rpc_method:, body:, timeout:, headers: nil, on_stdout: nil, on_stderr: nil, &block)
        stream = LiveEventStream.new
        start_queue = Queue.new
        start_signal_sent = false
        pid = nil
        stream_block = block

        stream_thread = Thread.new do
          Thread.current.report_on_exception = false if Thread.current.respond_to?(:report_on_exception=)

          begin
            envd_rpc("process.Process", rpc_method,
              body: body,
              timeout: timeout,
              headers: headers,
              on_event: lambda { |event_data|
                stream_event = event_data[:event]
                stream.push(stream_event) if stream_event

                stdout_chunk = event_data[:stdout]
                stderr_chunk = event_data[:stderr]

                on_stdout&.call(stdout_chunk) if stdout_chunk && !stdout_chunk.empty?
                on_stderr&.call(stderr_chunk) if stderr_chunk && !stderr_chunk.empty?

                stream_block&.call(:stdout, stdout_chunk) if stdout_chunk && !stdout_chunk.empty?
                stream_block&.call(:stderr, stderr_chunk) if stderr_chunk && !stderr_chunk.empty?

                unless start_signal_sent
                  extracted_pid = extract_pid_from_event(stream_event)
                  if extracted_pid
                    pid = extracted_pid
                    start_signal_sent = true
                    start_queue << [:pid, pid]
                  end
                end
              })

            unless start_signal_sent
              start_signal_sent = true
              start_queue << [:error, E2BError.new("Failed to start process: expected start event")]
            end
          rescue StandardError => e
            unless start_signal_sent
              start_signal_sent = true
              start_queue << [:error, e]
            end

            stream.fail(e)
          ensure
            stream.close
          end
        end

        start_state, start_value = start_queue.pop
        raise start_value if start_state == :error

        CommandHandle.new(
          pid: pid,
          handle_kill: -> { kill(pid, headers: headers) },
          handle_send_stdin: ->(data) { send_stdin(pid, data, headers: headers) },
          handle_disconnect: -> { disconnect_live_stream(stream_thread, stream) },
          events_proc: ->(&events_block) { stream.each(&events_block) }
        )
      end

      def extract_pid_from_event(event)
        return nil unless event.is_a?(Hash) && event["event"].is_a?(Hash)

        start_event = event["event"]["Start"] || event["event"]["start"]
        return nil unless start_event && start_event["pid"]

        start_event["pid"].to_i
      end

      def disconnect_live_stream(stream_thread, stream)
        stream.close(discard_pending: true)
        stream_thread.kill if stream_thread&.alive?
      end
    end
  end
end
