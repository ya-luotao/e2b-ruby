# frozen_string_literal: true

require "spec_helper"
require "time"

# Template-related models, all defined under E2B::Models.
RSpec.describe E2B::Models do
  describe E2B::Models::SnapshotInfo do
    it "reads the snapshot id from camelCase, snake_case or symbol keys" do
      expect(described_class.from_hash("snapshotID" => "snap_1").snapshot_id).to eq("snap_1")
      expect(described_class.from_hash("snapshot_id" => "snap_2").snapshot_id).to eq("snap_2")
      expect(described_class.from_hash(snapshotID: "snap_3").snapshot_id).to eq("snap_3")
    end
  end

  describe E2B::Models::TemplateTagInfo do
    it "maps build id and defaults tags to an empty array" do
      info = described_class.from_hash("buildID" => "b1", "tags" => %w[latest v1])
      expect(info.build_id).to eq("b1")
      expect(info.tags).to eq(%w[latest v1])

      expect(described_class.from_hash("build_id" => "b2").tags).to eq([])
    end
  end

  describe E2B::Models::TemplateTag do
    it "maps tag/build id and parses created_at" do
      tag = described_class.from_hash("tag" => "latest", "buildID" => "b1", "createdAt" => "2026-01-01T00:00:00Z")
      expect(tag.tag).to eq("latest")
      expect(tag.build_id).to eq("b1")
      expect(tag.created_at).to be_a(Time)
    end

    it "returns nil created_at for unparseable timestamps" do
      expect(described_class.from_hash("tag" => "t", "buildID" => "b", "createdAt" => "garbage").created_at).to be_nil
    end
  end

  describe E2B::Models::BuildInfo do
    it "maps fields and defaults tags / build_step_origins to arrays" do
      info = described_class.from_hash(
        "alias" => "my-template",
        "name" => "n",
        "templateID" => "tmpl_1",
        "buildID" => "b1"
      )
      expect(info.alias_name).to eq("my-template")
      expect(info.template_id).to eq("tmpl_1")
      expect(info.tags).to eq([])
      expect(info.build_step_origins).to eq([])
    end

    it "compacts nil entries out of build_step_origins" do
      info = described_class.from_hash("buildStepOrigins" => [1, nil, 2])
      expect(info.build_step_origins).to eq([1, 2])
    end
  end

  describe E2B::Models::TemplateLogEntry do
    it "maps level/message, parses the timestamp and strips ANSI codes" do
      entry = described_class.from_hash(
        "timestamp" => "2026-01-01T00:00:00Z",
        "level" => "info",
        "message" => "\e[31mred\e[0m text"
      )
      expect(entry.level).to eq("info")
      expect(entry.message).to eq("red text")
      expect(entry.timestamp).to be_a(Time)
    end

    it "renders to_s with timestamp, level and message" do
      entry = described_class.new(timestamp: Time.utc(2026, 1, 1), level: "warn", message: "hi")
      expect(entry.to_s).to include("[warn]").and include("hi")
    end

    describe "Start/End subclasses" do
      it "default to debug level" do
        expect(E2B::Models::TemplateLogEntryStart.new(timestamp: nil, message: "start").level).to eq("debug")
        expect(E2B::Models::TemplateLogEntryEnd.new(timestamp: nil, message: "end").level).to eq("debug")
      end
    end
  end

  describe E2B::Models::BuildStatusReason do
    it "returns nil when data is nil" do
      expect(described_class.from_hash(nil)).to be_nil
    end

    it "maps message/step and builds nested log entries" do
      reason = described_class.from_hash(
        "message" => "build failed",
        "step" => "RUN make",
        "logEntries" => [{ "level" => "error", "message" => "boom" }]
      )
      expect(reason.message).to eq("build failed")
      expect(reason.step).to eq("RUN make")
      expect(reason.log_entries.first).to be_a(E2B::Models::TemplateLogEntry)
      expect(reason.log_entries.first.message).to eq("boom")
    end
  end

  describe E2B::Models::TemplateBuildStatusResponse do
    it "maps fields, nested log entries and a nested reason" do
      response = described_class.from_hash(
        "buildID" => "b1",
        "templateID" => "tmpl_1",
        "status" => "error",
        "logEntries" => [{ "level" => "info", "message" => "step 1" }],
        "logs" => ["raw log"],
        "reason" => { "message" => "nope" }
      )
      expect(response.build_id).to eq("b1")
      expect(response.status).to eq("error")
      expect(response.log_entries.first.message).to eq("step 1")
      expect(response.logs).to eq(["raw log"])
      expect(response.reason).to be_a(E2B::Models::BuildStatusReason)
      expect(response.reason.message).to eq("nope")
    end

    it "leaves reason nil when absent" do
      expect(described_class.from_hash("buildID" => "b1", "status" => "building").reason).to be_nil
    end
  end
end
