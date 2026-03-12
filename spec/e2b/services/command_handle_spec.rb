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
end
