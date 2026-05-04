# frozen_string_literal: true

require "spec_helper"
require "base64"
require "timeout"

def process_start_event(pid)
  { "event" => { "Start" => { "pid" => pid } } }
end

def process_data_event(stdout: nil, stderr: nil, pty: nil)
  data = {}
  data["stdout"] = Base64.strict_encode64(stdout) if stdout
  data["stderr"] = Base64.strict_encode64(stderr) if stderr
  data["pty"] = Base64.strict_encode64(pty) if pty
  { "event" => { "Data" => data } }
end

def process_end_event(exit_code:, error: nil)
  payload = { "exitCode" => exit_code }
  payload["error"] = error if error
  { "event" => { "End" => payload } }
end

RSpec.describe E2B::Services::Commands do
  subject(:commands) do
    described_class.new(
      sandbox_id: "sbx_123",
      sandbox_domain: "e2b.app",
      api_key: "api-key"
    )
  end

  let(:auth_headers) { { "Authorization" => "Basic #{Base64.strict_encode64("alice:")}" } }

  describe "#run" do
    it "runs commands through a login bash shell, normalizes env vars, and propagates user auth" do
      expect(commands).to receive(:envd_rpc)
        .with(
          "process.Process",
          "Start",
          body: {
            process: {
              cmd: "/bin/bash",
              args: ["-l", "-c", "echo hi"],
              envs: { "RUBYOPT" => "warn" },
              cwd: "/workspace"
            },
            stdin: false
          },
          timeout: 90,
          headers: auth_headers,
          on_event: nil
        )
        .and_return(
          stdout: "hi\n",
          stderr: "",
          exit_code: 0,
          events: [{ "event" => { "End" => { "exitCode" => 0 } } }]
        )

      result = commands.run("echo hi", envs: { RUBYOPT: :warn }, cwd: "/workspace", timeout: 60, user: "alice")

      expect(result).to be_a(E2B::Services::CommandResult)
      expect(result.stdout).to eq("hi\n")
      expect(result).to be_success
    end

    it "streams stdout and stderr chunks to callbacks and blocks" do
      streamed = []
      allow(commands).to receive(:envd_rpc) do |_service, _method, body:, timeout:, headers:, on_event:|
        expect(body).to eq(process: { cmd: "/bin/bash", args: ["-l", "-c", "run me"] }, stdin: false)
        expect(timeout).to eq(31)
        expect(headers).to be_nil

        on_event.call(
          stdout: "hello",
          stderr: nil,
          exit_code: nil,
          event: { "event" => { "Data" => { "stdout" => Base64.strict_encode64("hello") } } }
        )
        on_event.call(
          stdout: nil,
          stderr: "warn",
          exit_code: nil,
          event: { "event" => { "Data" => { "stderr" => Base64.strict_encode64("warn") } } }
        )

        {
          stdout: "hello",
          stderr: "warn",
          exit_code: 0,
          events: [{ "event" => { "End" => { "exitCode" => 0 } } }]
        }
      end

      result = commands.run(
        "run me",
        timeout: 1,
        on_stdout: ->(chunk) { streamed << [:stdout, chunk] },
        on_stderr: ->(chunk) { streamed << [:stderr, chunk] }
      ) do |stream, chunk|
        streamed << [stream, chunk]
      end

      expect(result.output).to eq("hellowarn")
      expect(streamed).to eq([
        [:stdout, "hello"],
        [:stdout, "hello"],
        [:stderr, "warn"],
        [:stderr, "warn"]
      ])
    end

    it "returns a live handle for background commands, waits on streamed output, and preserves user auth" do
      release_stream = Queue.new
      streamed_during_run = []

      allow(commands).to receive(:envd_rpc) do |_service, method, body:, timeout:, headers:, on_event:|
        expect(method).to eq("Start")
        expect(body).to eq(process: { cmd: "/bin/bash", args: ["-l", "-c", "sleep 30"] }, stdin: false)
        expect(timeout).to eq(90)
        expect(headers).to eq(auth_headers)

        on_event.call(stdout: nil, stderr: nil, exit_code: nil, event: process_start_event(42))
        release_stream.pop
        on_event.call(stdout: "hello", stderr: nil, exit_code: nil, event: process_data_event(stdout: "hello"))
        on_event.call(stdout: nil, stderr: "warn", exit_code: nil, event: process_data_event(stderr: "warn"))
        on_event.call(stdout: nil, stderr: nil, exit_code: 0, event: process_end_event(exit_code: 0))

        { stdout: "hello", stderr: "warn", exit_code: 0, events: [] }
      end

      allow(commands).to receive(:kill).with(42, headers: auth_headers).and_return(true)
      allow(commands).to receive(:send_stdin).with(42, "exit\n", headers: auth_headers)

      handle = Timeout.timeout(1) do
        commands.run(
          "sleep 30",
          background: true,
          user: "alice",
          on_stdout: ->(chunk) { streamed_during_run << [:stdout, chunk] },
          on_stderr: ->(chunk) { streamed_during_run << [:stderr, chunk] }
        )
      end

      expect(handle.pid).to eq(42)
      expect(handle.kill).to be(true)
      handle.send_stdin("exit\n")

      streamed_while_waiting = []
      release_stream << true
      result = handle.wait(
        on_stdout: ->(chunk) { streamed_while_waiting << [:stdout, chunk] },
        on_stderr: ->(chunk) { streamed_while_waiting << [:stderr, chunk] }
      )

      expect(result.output).to eq("hellowarn")
      expect(streamed_during_run).to eq([[:stdout, "hello"], [:stderr, "warn"]])
      expect(streamed_while_waiting).to eq([[:stdout, "hello"], [:stderr, "warn"]])
    end

    it "raises CommandExitError for non-zero exit codes" do
      allow(commands).to receive(:envd_rpc).and_return(
        stdout: "partial output",
        stderr: "boom",
        exit_code: "2",
        events: [
          { "event" => { "End" => { "exitCode" => "2", "error" => "command failed" } } }
        ]
      )

      expect { commands.run("false") }
        .to raise_error(E2B::CommandExitError) { |error|
          expect(error.stdout).to eq("partial output")
          expect(error.stderr).to eq("boom")
          expect(error.exit_code).to eq(2)
          expect(error.command_error).to eq("command failed")
        }
    end
  end

  describe "#connect" do
    it "returns a live handle that can stream before wait" do
      release_stream = Queue.new

      allow(commands).to receive(:envd_rpc) do |_service, method, body:, timeout:, headers:, on_event:|
        expect(method).to eq("Connect")
        expect(body).to eq(process: { pid: 42 })
        expect(timeout).to eq(45)
        expect(headers).to be_nil

        on_event.call(stdout: nil, stderr: nil, exit_code: nil, event: process_start_event(42))
        release_stream.pop
        on_event.call(stdout: "reconnected", stderr: nil, exit_code: nil, event: process_data_event(stdout: "reconnected"))
        on_event.call(stdout: nil, stderr: nil, exit_code: 0, event: process_end_event(exit_code: 0))

        { stdout: "reconnected", stderr: "", exit_code: 0, events: [] }
      end

      handle = Timeout.timeout(1) { commands.connect(42, timeout: 15) }

      release_stream << true
      chunks = []
      handle.each do |stdout, stderr, pty|
        chunks << [stdout, stderr, pty]
      end

      expect(chunks).to eq([["reconnected", nil, nil]])
      expect(handle.wait.stdout).to eq("reconnected")
    end
  end

  describe "legacy envd user defaults" do
    it "sends the default user header when running commands on older envd versions" do
      old_commands = described_class.new(
        sandbox_id: "sbx_123",
        sandbox_domain: "e2b.app",
        api_key: "api-key",
        envd_version: "0.3.9"
      )

      expect(old_commands).to receive(:envd_rpc)
        .with(
          "process.Process",
          "Start",
          body: {
            process: {
              cmd: "/bin/bash",
              args: ["-l", "-c", "echo hi"]
            },
            stdin: false
          },
          timeout: 90,
          headers: { "Authorization" => "Basic #{Base64.strict_encode64("user:")}" },
          on_event: nil
        )
        .and_return(
          stdout: "hi\n",
          stderr: "",
          exit_code: 0,
          events: [{ "event" => { "End" => { "exitCode" => 0 } } }]
        )

      result = old_commands.run("echo hi", timeout: 60)

      expect(result.stdout).to eq("hi\n")
    end
  end

  describe "#list" do
    it "collects process entries from streaming events" do
      allow(commands).to receive(:envd_rpc).and_return(
        events: [
          { "processes" => [{ "pid" => 1 }] },
          { "result" => "ignored" },
          { "processes" => [{ "pid" => 2 }] }
        ]
      )

      expect(commands.list).to eq([{ "pid" => 1 }, { "pid" => 2 }])
    end
  end

  describe "#kill" do
    it "returns false when the process is not found" do
      allow(commands).to receive(:envd_rpc).and_raise(E2B::NotFoundError, "missing")

      expect(commands.kill(99)).to be(false)
    end
  end
end
