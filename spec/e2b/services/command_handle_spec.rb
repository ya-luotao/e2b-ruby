# frozen_string_literal: true

require "spec_helper"
require "base64"

def command_handle_start_event(pid)
  { "event" => { "Start" => { "pid" => pid } } }
end

def command_handle_data_event(stdout: nil, stderr: nil, pty: nil)
  data = {}
  data["stdout"] = Base64.strict_encode64(stdout) if stdout
  data["stderr"] = Base64.strict_encode64(stderr) if stderr
  data["pty"] = Base64.strict_encode64(pty) if pty
  { "event" => { "Data" => data } }
end

def command_handle_end_event(exit_code:, error: nil)
  payload = { "exitCode" => exit_code }
  payload["error"] = error if error
  { "event" => { "End" => payload } }
end

RSpec.describe E2B::Services::CommandHandle do
  let(:stream) { E2B::Services::LiveEventStream.new }
  let(:handle) do
    described_class.new(
      pid: 42,
      handle_kill: -> { true },
      handle_send_stdin: ->(_data) {},
      handle_disconnect: -> { stream.close(discard_pending: true) },
      events_proc: ->(&block) { stream.each(&block) }
    )
  end

  it "keeps streamed output available after iterating with each" do
    producer = Thread.new do
      stream.push(command_handle_start_event(42))
      stream.push(command_handle_data_event(stdout: "hello"))
      stream.push(command_handle_end_event(exit_code: 0))
      stream.close
    end

    chunks = []
    handle.each do |stdout, stderr, pty|
      chunks << [stdout, stderr, pty]
    end

    producer.join

    expect(chunks).to eq([["hello", nil, nil]])
    expect(handle.wait.stdout).to eq("hello")
  end

  it "raises when a live stream closes without an end event" do
    producer = Thread.new do
      stream.push(command_handle_start_event(42))
      stream.push(command_handle_data_event(stdout: "partial"))
      stream.close
    end

    expect { handle.wait }.to raise_error(E2B::E2BError, "Command ended without an end event")

    producer.join
  end

  describe "delegation to handle procs" do
    it "forwards kill and send_stdin to their procs" do
      sent = []
      handle = described_class.new(
        pid: 7,
        handle_kill: -> { :killed },
        handle_send_stdin: ->(data) { sent << data },
        events_proc: ->(&_block) {}
      )

      expect(handle.pid).to eq(7)
      expect(handle.kill).to eq(:killed)
      handle.send_stdin("input\n")
      expect(sent).to eq(["input\n"])
    end
  end

  describe "materialized (synchronous) result" do
    def materialized_handle(result)
      described_class.new(
        pid: 1,
        handle_kill: -> { true },
        handle_send_stdin: ->(_d) {},
        result: result
      )
    end

    it "iterates pre-materialized events separating stdout, stderr and pty" do
      handle = materialized_handle(
        events: [
          command_handle_start_event(1),
          command_handle_data_event(stdout: "out"),
          command_handle_data_event(stderr: "err"),
          command_handle_data_event(pty: "tty"),
          command_handle_end_event(exit_code: 0)
        ]
      )

      chunks = []
      handle.each { |stdout, stderr, pty| chunks << [stdout, stderr, pty] }

      expect(chunks).to eq([["out", nil, nil], [nil, "err", nil], [nil, nil, "tty"]])
    end

    it "returns a successful CommandResult and invokes output callbacks" do
      handle = materialized_handle(
        events: [
          command_handle_data_event(stdout: "hello "),
          command_handle_data_event(stdout: "world"),
          command_handle_end_event(exit_code: 0)
        ]
      )

      streamed = []
      result = handle.wait(on_stdout: ->(chunk) { streamed << chunk })

      expect(result).to be_a(E2B::Services::CommandResult)
      expect(result.stdout).to eq("hello world")
      expect(result.exit_code).to eq(0)
      expect(result).to be_success
      expect(streamed).to eq(["hello ", "world"])
    end

    it "raises CommandExitError with captured output on a non-zero exit" do
      handle = materialized_handle(
        events: [
          command_handle_data_event(stdout: "partial"),
          command_handle_data_event(stderr: "boom"),
          command_handle_end_event(exit_code: 2, error: "command failed")
        ]
      )

      expect { handle.wait }.to raise_error(E2B::CommandExitError) do |error|
        expect(error.stdout).to eq("partial")
        expect(error.stderr).to eq("boom")
        expect(error.exit_code).to eq(2)
        expect(error.command_error).to eq("command failed")
      end
    end

    it "parses an 'exit status N' end event into an integer exit code" do
      handle = materialized_handle(
        events: [command_handle_end_event(exit_code: "exit status 137")]
      )

      expect { handle.wait }.to raise_error(E2B::CommandExitError) do |error|
        expect(error.exit_code).to eq(137)
      end
    end

    it "falls back to the result hash stdout/exit_code when events are not iterated" do
      handle = materialized_handle(stdout: "cached", stderr: "", exit_code: 0, events: [])
      expect(handle.wait.stdout).to eq("cached")
    end
  end

  describe "#disconnect" do
    it "stops streaming iteration and lets wait return accumulated output" do
      handle = described_class.new(
        pid: 9,
        handle_kill: -> { true },
        handle_send_stdin: ->(_d) {},
        handle_disconnect: -> { stream.close(discard_pending: true) },
        events_proc: ->(&block) { stream.each(&block) }
      )

      producer = Thread.new do
        stream.push(command_handle_start_event(9))
        stream.push(command_handle_data_event(stdout: "before disconnect"))
        # Keep the stream open; disconnect should be what ends iteration.
        sleep 0.05
        stream.close
      end

      received = nil
      handle.each do |stdout, _stderr, _pty|
        received = stdout if stdout
        handle.disconnect
      end

      result = handle.wait
      expect(received).to eq("before disconnect")
      expect(result.stdout).to eq("before disconnect")

      producer.join
    end
  end
end
