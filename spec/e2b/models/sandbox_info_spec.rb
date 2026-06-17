# frozen_string_literal: true

require "spec_helper"
require "time"

RSpec.describe E2B::Models::SandboxInfo do
  describe ".from_hash" do
    it "maps camelCase API keys and parses timestamps" do
      info = described_class.from_hash(
        "sandboxID" => "sbx_1",
        "templateID" => "tmpl_1",
        "alias" => "my-box",
        "clientID" => "client_1",
        "startedAt" => "2026-01-01T00:00:00Z",
        "endAt" => "2026-01-01T01:00:00Z",
        "cpuCount" => 2,
        "memoryMB" => 512,
        "metadata" => { "k" => "v" },
        "state" => "running",
        "domain" => "e2b.app",
        "envdVersion" => "0.4.0"
      )

      expect(info.sandbox_id).to eq("sbx_1")
      expect(info.template_id).to eq("tmpl_1")
      expect(info.alias_name).to eq("my-box")
      expect(info.started_at).to be_a(Time)
      expect(info.cpu_count).to eq(2)
      expect(info.metadata).to eq("k" => "v")
      expect(info.envd_version).to eq("0.4.0")
    end

    it "defaults metadata to an empty hash" do
      expect(described_class.from_hash("sandboxID" => "x").metadata).to eq({})
    end
  end

  describe "#running?" do
    it "is false when state is paused" do
      info = described_class.new(sandbox_id: "x", template_id: "t", state: "paused")
      expect(info.running?).to be(false)
    end

    it "is true when there is no end time" do
      info = described_class.new(sandbox_id: "x", template_id: "t")
      expect(info.running?).to be(true)
    end

    it "is false once end_at is in the past" do
      info = described_class.new(sandbox_id: "x", template_id: "t", end_at: Time.now - 60)
      expect(info.running?).to be(false)
    end
  end

  describe "#time_remaining" do
    it "returns 0 when expired or end_at is nil" do
      expect(described_class.new(sandbox_id: "x", template_id: "t").time_remaining).to eq(0)
      expect(described_class.new(sandbox_id: "x", template_id: "t", end_at: Time.now - 5).time_remaining).to eq(0)
    end

    it "returns positive seconds when still running" do
      info = described_class.new(sandbox_id: "x", template_id: "t", end_at: Time.now + 120)
      expect(info.time_remaining).to be > 0
    end
  end

  describe ".parse_time" do
    it "passes Time through, parses strings, and returns nil on garbage" do
      now = Time.now
      expect(described_class.parse_time(now)).to eq(now)
      expect(described_class.parse_time("2026-01-01T00:00:00Z")).to be_a(Time)
      expect(described_class.parse_time("not-a-time")).to be_nil
      expect(described_class.parse_time(nil)).to be_nil
    end
  end
end
