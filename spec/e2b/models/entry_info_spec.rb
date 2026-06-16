# frozen_string_literal: true

require "spec_helper"
require "time"

# EntryInfo and FilesystemEvent are sibling models defined in entry_info.rb.
RSpec.describe E2B::Models do
  describe E2B::Models::EntryInfo do
    describe ".from_hash" do
      it "returns nil for non-Hash input" do
        expect(described_class.from_hash("nope")).to be_nil
      end

      it "maps numeric protobuf file types to constants" do
        expect(described_class.from_hash("type" => 1).type).to eq(E2B::Models::FileType::FILE)
        expect(described_class.from_hash("type" => 2).type).to eq(E2B::Models::FileType::DIRECTORY)
      end

      it "maps string enum names to constants" do
        expect(described_class.from_hash("type" => "FILE_TYPE_DIRECTORY").type)
          .to eq(E2B::Models::FileType::DIRECTORY)
      end

      it "reads camelCase and snake_case keys and coerces numeric fields" do
        entry = described_class.from_hash(
          "name" => "f.txt",
          "type" => 1,
          "path" => "/home/user/f.txt",
          "size" => "13",
          "mode" => "420",
          "permissions" => "0644",
          "owner" => "user",
          "group" => "user",
          "symlinkTarget" => "/elsewhere"
        )

        expect(entry.name).to eq("f.txt")
        expect(entry.size).to eq(13)
        expect(entry.mode).to eq(420)
        expect(entry.symlink_target).to eq("/elsewhere")
        expect(entry.file?).to be(true)
        expect(entry.directory?).to be(false)
      end

      it "parses a protobuf Timestamp hash for modified_time" do
        seconds = 1_700_000_000
        entry = described_class.from_hash("type" => 1, "modifiedTime" => { "seconds" => seconds })
        expect(entry.modified_time).to eq(Time.at(seconds))
      end

      it "parses an ISO string modified_time" do
        entry = described_class.from_hash("type" => 1, "modified_time" => "2026-01-01T00:00:00Z")
        expect(entry.modified_time).to be_a(Time)
      end
    end
  end

  describe E2B::Models::FilesystemEvent do
    describe ".from_hash" do
      it "maps numeric event types to constants" do
        expect(described_class.from_hash("name" => "a", "type" => 1).type)
          .to eq(E2B::Models::FilesystemEventType::CREATE)
        expect(described_class.from_hash("name" => "a", "type" => 3).type)
          .to eq(E2B::Models::FilesystemEventType::REMOVE)
      end

      it "maps string enum names to constants and reads the name" do
        event = described_class.from_hash("name" => "b.txt", "type" => "EVENT_TYPE_WRITE")
        expect(event.name).to eq("b.txt")
        expect(event.type).to eq(E2B::Models::FilesystemEventType::WRITE)
      end

      it "falls back to the raw value string for unknown types" do
        expect(described_class.from_hash("name" => "a", "type" => "WEIRD").type).to eq("WEIRD")
      end
    end
  end
end
