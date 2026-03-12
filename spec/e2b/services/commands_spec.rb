# frozen_string_literal: true

require "spec_helper"
require "base64"

RSpec.describe E2B::Services::Commands do
  subject(:commands) do
    described_class.new(
      sandbox_id: "sbx_123",
      sandbox_domain: "e2b.app",
      api_key: "api-key"
    )
  end

  describe "#run" do
    it "runs commands through a login bash shell and normalizes env vars" do
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
            }
          },
          timeout: 90,
          on_event: nil
        )
        .and_return(
          stdout: "hi\n",
          stderr: "",
          exit_code: 0,
          events: [{ "event" => { "End" => { "exitCode" => 0 } } }]
        )

      result = commands.run("echo hi", envs: { RUBYOPT: :warn }, cwd: "/workspace", timeout: 60)

      expect(result).to be_a(E2B::Services::CommandResult)
      expect(result.stdout).to eq("hi\n")
      expect(result).to be_success
    end

    it "streams stdout and stderr chunks to callbacks and blocks" do
      streamed = []
      allow(commands).to receive(:envd_rpc) do |_service, _method, body:, timeout:, on_event:|
        expect(body).to eq(process: { cmd: "/bin/bash", args: ["-l", "-c", "run me"] })
        expect(timeout).to eq(31)

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

    it "returns a handle for background commands and extracts the pid from events" do
      allow(commands).to receive(:envd_rpc).and_return(
        stdout: "",
        stderr: "",
        exit_code: nil,
        events: [
          { "event" => { "Start" => { "pid" => 42 } } }
        ]
      )

      handle = commands.run("sleep 30", background: true)

      expect(handle.pid).to eq(42)

      allow(commands).to receive(:kill).with(42).and_return(true)
      allow(commands).to receive(:send_stdin).with(42, "exit\n")

      expect(handle.kill).to be(true)
      handle.send_stdin("exit\n")
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
