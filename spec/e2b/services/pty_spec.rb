# frozen_string_literal: true

require "spec_helper"
require "base64"
require "timeout"

def pty_process_start_event(pid)
  { "event" => { "Start" => { "pid" => pid } } }
end

def pty_process_data_event(stdout: nil, stderr: nil, pty: nil)
  data = {}
  data["stdout"] = Base64.strict_encode64(stdout) if stdout
  data["stderr"] = Base64.strict_encode64(stderr) if stderr
  data["pty"] = Base64.strict_encode64(pty) if pty
  { "event" => { "Data" => data } }
end

def pty_process_end_event(exit_code:, error: nil)
  payload = { "exitCode" => exit_code }
  payload["error"] = error if error
  { "event" => { "End" => payload } }
end

RSpec.describe E2B::Services::Pty do
  subject(:pty_service) do
    described_class.new(
      sandbox_id: "sbx_123",
      sandbox_domain: "e2b.app",
      api_key: "api-key"
    )
  end

  let(:auth_headers) { { "Authorization" => "Basic #{Base64.strict_encode64("alice:")}" } }

  describe "#create" do
    it "returns a live handle that streams PTY output" do
      release_stream = Queue.new

      allow(pty_service).to receive(:envd_rpc) do |_service, method, body:, timeout:, headers:, on_event:|
        expect(method).to eq("Start")
        expect(body).to eq(
          process: {
            cmd: "/bin/bash",
            args: ["-i", "-l"],
            envs: {
              "TERM" => "xterm-256color",
              "LANG" => "C.UTF-8",
              "LC_ALL" => "C.UTF-8",
              "EDITOR" => "vim"
            },
            cwd: "/workspace"
          },
          pty: {
            size: {
              cols: 120,
              rows: 40
            }
          }
        )
        expect(timeout).to eq(35)
        expect(headers).to eq(auth_headers)

        on_event.call(stdout: nil, stderr: nil, exit_code: nil, event: pty_process_start_event(77))
        release_stream.pop
        on_event.call(stdout: nil, stderr: nil, exit_code: nil, event: pty_process_data_event(pty: "$ "))
        on_event.call(stdout: nil, stderr: nil, exit_code: 0, event: pty_process_end_event(exit_code: 0))

        { stdout: "", stderr: "", exit_code: 0, events: [] }
      end

      allow(pty_service).to receive(:kill).with(77, headers: auth_headers).and_return(true)
      allow(pty_service).to receive(:send_stdin).with(77, "pwd\n", headers: auth_headers)

      handle = Timeout.timeout(1) do
        pty_service.create(
          size: E2B::Services::PtySize.new(cols: 120, rows: 40),
          cwd: "/workspace",
          envs: { EDITOR: :vim },
          user: "alice",
          timeout: 5
        )
      end

      expect(handle.pid).to eq(77)
      expect(handle.kill).to be(true)
      handle.send_stdin("pwd\n")

      streamed = []
      release_stream << true
      result = handle.wait(on_pty: ->(chunk) { streamed << chunk })

      expect(streamed).to eq(["$ "])
      expect(result).to be_success
    end
  end

  describe "#connect" do
    it "returns a live handle for connected PTYs" do
      release_stream = Queue.new

      allow(pty_service).to receive(:envd_rpc) do |_service, method, body:, timeout:, headers:, on_event:|
        expect(method).to eq("Connect")
        expect(body).to eq(process: { pid: 77 })
        expect(timeout).to eq(45)
        expect(headers).to be_nil

        on_event.call(stdout: nil, stderr: nil, exit_code: nil, event: pty_process_start_event(77))
        release_stream.pop
        on_event.call(stdout: nil, stderr: nil, exit_code: nil, event: pty_process_data_event(pty: "whoami\r\nuser\r\n"))
        on_event.call(stdout: nil, stderr: nil, exit_code: 0, event: pty_process_end_event(exit_code: 0))

        { stdout: "", stderr: "", exit_code: 0, events: [] }
      end

      handle = Timeout.timeout(1) { pty_service.connect(77, timeout: 15) }

      release_stream << true
      chunks = []
      handle.each do |stdout, stderr, pty|
        chunks << [stdout, stderr, pty]
      end

      expect(chunks).to eq([[nil, nil, "whoami\r\nuser\r\n"]])
      expect(handle.wait.exit_code).to eq(0)
    end
  end
end
