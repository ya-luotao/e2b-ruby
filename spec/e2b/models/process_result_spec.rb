# frozen_string_literal: true

require "spec_helper"
require "base64"

RSpec.describe E2B::Models::ProcessResult do
  describe ".from_hash" do
    it "reads camelCase, snake_case and symbol keys with sensible defaults" do
      result = described_class.from_hash("stdout" => "out", "stderr" => "err", "exitCode" => 3)
      expect([result.stdout, result.stderr, result.exit_code]).to eq(["out", "err", 3])

      symbol_result = described_class.from_hash(stdout: "o", exitCode: 5)
      expect(symbol_result.exit_code).to eq(5)

      expect(described_class.from_hash({}).exit_code).to eq(0)
    end
  end

  describe ".from_connect_response" do
    it "extracts accumulated stdout/stderr/exit_code from a flat response" do
      result = described_class.from_connect_response(stdout: "hi", exit_code: 0)
      expect(result.stdout).to eq("hi")
      expect(result).to be_success
    end

    it "decodes and accumulates output from streaming events when stdout is empty" do
      data = {
        stdout: "",
        events: [
          { "event" => { "Stdout" => { "data" => Base64.strict_encode64("hello ") } } },
          { "event" => { "stdout" => { "data" => Base64.strict_encode64("world") } } },
          { "event" => { "Stderr" => { "data" => Base64.strict_encode64("oops") } } },
          { "event" => { "Exit" => { "exitCode" => 7 } } }
        ]
      }

      result = described_class.from_connect_response(data)
      expect(result.stdout).to eq("hello world")
      expect(result.stderr).to eq("oops")
      expect(result.exit_code).to eq(7)
    end
  end

  describe ".parse_exit_code" do
    it "handles nil, integers, numeric strings and 'exit status N'" do
      expect(described_class.parse_exit_code(nil)).to eq(0)
      expect(described_class.parse_exit_code(42)).to eq(42)
      expect(described_class.parse_exit_code("13")).to eq(13)
      expect(described_class.parse_exit_code("exit status 137")).to eq(137)
    end
  end

  describe "#success? and #output" do
    it "is successful only with exit code 0 and no error" do
      expect(described_class.new(exit_code: 0)).to be_success
      expect(described_class.new(exit_code: 1)).not_to be_success
      expect(described_class.new(exit_code: 0, error: "boom")).not_to be_success
    end

    it "concatenates stdout and stderr for #output and aliases #result to stdout" do
      result = described_class.new(stdout: "a", stderr: "b")
      expect(result.output).to eq("ab")
      expect(result.result).to eq("a")
    end
  end
end
