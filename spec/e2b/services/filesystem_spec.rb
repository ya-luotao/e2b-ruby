# frozen_string_literal: true

require "spec_helper"
require "base64"
require "stringio"

RSpec.describe E2B::Services::Filesystem do
  subject(:filesystem) do
    described_class.new(
      sandbox_id: "sbx_123",
      sandbox_domain: "custom.e2b.test",
      api_key: "api-key",
      access_token: "envd-token"
    )
  end

  let(:auth_headers) { { "Authorization" => "Basic #{Base64.strict_encode64("alice:")}" } }

  describe "#read" do
    it "returns text, bytes, and stream formats" do
      allow(filesystem).to receive(:rest_get).and_return("hello".b)

      expect(filesystem.read("/tmp/hello.txt")).to eq("hello")
      expect(filesystem.read("/tmp/hello.txt", format: "bytes")).to eq("hello".b)

      stream = filesystem.read("/tmp/hello.txt", format: "stream")
      expect(stream).to be_a(StringIO)
      expect(stream.read).to eq("hello".b)
    end

    it "raises for unsupported formats" do
      allow(filesystem).to receive(:rest_get).and_return("hello")

      expect { filesystem.read("/tmp/hello.txt", format: "json") }
        .to raise_error(ArgumentError, "Unsupported read format 'json'")
    end
  end

  describe "#write" do
    it "returns WriteInfo built from the upload response" do
      expect(filesystem).to receive(:rest_upload)
        .with(
          "https://49983-sbx_123.custom.e2b.test/files?path=%2Ftmp%2Fout.txt&username=user",
          "payload",
          timeout: 120
        )
        .and_return([{ "path" => "/tmp/out.txt" }])

      info = filesystem.write("/tmp/out.txt", "payload")

      expect(info).to be_a(E2B::Models::WriteInfo)
      expect(info.path).to eq("/tmp/out.txt")
    end
  end

  describe "#list" do
    it "sends the per-user authorization header" do
      expect(filesystem).to receive(:envd_rpc)
        .with(
          "filesystem.Filesystem",
          "ListDir",
          body: { path: "/tmp", depth: 2 },
          timeout: 15,
          headers: auth_headers
        )
        .and_return("entries" => [])

      expect(filesystem.list("/tmp", depth: 2, user: "alice", request_timeout: 15)).to eq([])
    end
  end

  describe "#watch_dir" do
    it "reuses per-user authorization headers for watcher polling and cleanup" do
      expect(filesystem).to receive(:envd_rpc)
        .with(
          "filesystem.Filesystem",
          "CreateWatcher",
          body: { path: "/tmp", recursive: true },
          timeout: 12,
          headers: auth_headers
        )
        .and_return("watcherId" => "watch-1")

      expect(filesystem).to receive(:envd_rpc)
        .with(
          "filesystem.Filesystem",
          "GetWatcherEvents",
          body: { watcherId: "watch-1" },
          headers: auth_headers
        )
        .and_return("events" => [])

      expect(filesystem).to receive(:envd_rpc)
        .with(
          "filesystem.Filesystem",
          "RemoveWatcher",
          body: { watcherId: "watch-1" },
          headers: auth_headers
        )

      handle = filesystem.watch_dir("/tmp", recursive: true, user: "alice", request_timeout: 12)

      expect(handle.get_new_events).to eq([])
      handle.stop
      expect(handle).to be_stopped
    end
  end
end
