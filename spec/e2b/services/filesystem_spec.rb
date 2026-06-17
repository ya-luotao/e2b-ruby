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
          "https://49983-sbx_123.custom.e2b.test/files?path=%2Ftmp%2Fout.txt",
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

    it "raises TemplateError when recursive watching is requested on unsupported envd versions" do
      old_filesystem = described_class.new(
        sandbox_id: "sbx_123",
        sandbox_domain: "custom.e2b.test",
        api_key: "api-key",
        access_token: "envd-token",
        envd_version: "0.1.3"
      )

      expect { old_filesystem.watch_dir("/tmp", recursive: true) }
        .to raise_error(E2B::TemplateError, /update the template to use recursive watching/)
    end
  end

  # An RPC response whose single event carries an "entry" payload, the shape
  # Stat/Move responses arrive in once the Connect envelope is parsed.
  def entry_response(overrides = {})
    { events: [{ "entry" => { "name" => "f.txt", "type" => 1, "path" => "/tmp/f.txt", "size" => 5 }.merge(overrides) }] }
  end

  describe "#get_info" do
    it "parses the Stat response into an EntryInfo" do
      allow(filesystem).to receive(:envd_rpc).and_return(entry_response)

      info = filesystem.get_info("/tmp/f.txt")

      expect(info).to be_a(E2B::Models::EntryInfo)
      expect(info.name).to eq("f.txt")
      expect(info).to be_file
      expect(info.size).to eq(5)
    end
  end

  describe "#exists?" do
    it "returns true when Stat succeeds" do
      allow(filesystem).to receive(:envd_rpc).and_return(entry_response)
      expect(filesystem.exists?("/tmp/f.txt")).to be(true)
    end

    it "returns false only for NotFoundError" do
      allow(filesystem).to receive(:envd_rpc).and_raise(E2B::NotFoundError.new("gone", status_code: 404))
      expect(filesystem.exists?("/missing")).to be(false)
    end

    it "propagates errors other than NotFoundError so callers can tell 'gone' from 'could not ask'" do
      allow(filesystem).to receive(:envd_rpc).and_raise(E2B::E2BError.new("network down"))
      expect { filesystem.exists?("/x") }.to raise_error(E2B::E2BError, "network down")
    end
  end

  describe "#rename" do
    it "sends source/destination and parses the moved entry" do
      expect(filesystem).to receive(:envd_rpc)
        .with("filesystem.Filesystem", "Move",
              hash_including(body: { source: "/a.txt", destination: "/b.txt" }))
        .and_return(entry_response("name" => "b.txt", "path" => "/b.txt"))

      info = filesystem.rename("/a.txt", "/b.txt")
      expect(info.path).to eq("/b.txt")
    end
  end

  describe "#make_dir" do
    it "returns true after issuing the MakeDir RPC" do
      expect(filesystem).to receive(:envd_rpc)
        .with("filesystem.Filesystem", "MakeDir", hash_including(body: { path: "/tmp/new" }))
        .and_return({})

      expect(filesystem.make_dir("/tmp/new")).to be(true)
    end
  end

  describe "#remove" do
    it "issues the Remove RPC for the path" do
      expect(filesystem).to receive(:envd_rpc)
        .with("filesystem.Filesystem", "Remove", hash_including(body: { path: "/tmp/gone" }))
        .and_return({})

      filesystem.remove("/tmp/gone")
    end
  end

  describe "#write_files" do
    it "writes each entry and accepts both :data and :content keys" do
      allow(filesystem).to receive(:write) do |path, data, **|
        E2B::Models::WriteInfo.new(path: "#{path}:#{data}")
      end

      infos = filesystem.write_files([
                                       { path: "/a.txt", data: "A" },
                                       { path: "/b.txt", content: "B" }
                                     ])

      expect(infos.map(&:path)).to eq(["/a.txt:A", "/b.txt:B"])
    end
  end

  describe "backward-compatible aliases" do
    it "maps legacy method names onto their modern equivalents" do
      expect(filesystem.method(:read_file)).to eq(filesystem.method(:read))
      expect(filesystem.method(:write_file)).to eq(filesystem.method(:write))
      expect(filesystem.method(:list_files)).to eq(filesystem.method(:list))
      expect(filesystem.method(:mkdir)).to eq(filesystem.method(:make_dir))
      expect(filesystem.method(:create_folder)).to eq(filesystem.method(:make_dir))
      expect(filesystem.method(:move)).to eq(filesystem.method(:rename))
      expect(filesystem.method(:move_files)).to eq(filesystem.method(:rename))
      expect(filesystem.method(:delete_file)).to eq(filesystem.method(:remove))
    end
  end

  describe "private response parsing" do
    it "build_file_url percent-encodes the path and username query params" do
      url = filesystem.send(:build_file_url, "/files", path: "/tmp/a b.txt", user: "alice")
      expect(url).to eq("https://49983-sbx_123.custom.e2b.test/files?path=%2Ftmp%2Fa+b.txt&username=alice")
    end

    it "extract_entries reads entries from a direct event field" do
      response = { events: [{ "entries" => [{ "name" => "a" }] }] }
      expect(filesystem.send(:extract_entries, response)).to eq([{ "name" => "a" }])
    end

    it "extract_entries reads entries nested under result" do
      response = { events: [{ "result" => { "entries" => [{ "name" => "b" }] } }] }
      expect(filesystem.send(:extract_entries, response)).to eq([{ "name" => "b" }])
    end

    it "extract_entries falls back to a top-level entries key" do
      expect(filesystem.send(:extract_entries, { "entries" => [{ "name" => "c" }] })).to eq([{ "name" => "c" }])
    end

    it "extract_entries returns [] for a non-Hash response" do
      expect(filesystem.send(:extract_entries, "nope")).to eq([])
    end

    it "extract_entry prefers an event entry, then result.entry, then top-level" do
      expect(filesystem.send(:extract_entry, { events: [{ "entry" => { "name" => "x" } }] })).to eq({ "name" => "x" })
      expect(filesystem.send(:extract_entry, { events: [{ "result" => { "entry" => { "name" => "y" } } }] }))
        .to eq({ "name" => "y" })
      expect(filesystem.send(:extract_entry, { "entry" => { "name" => "z" } })).to eq({ "name" => "z" })
      expect(filesystem.send(:extract_entry, "nope")).to eq({})
    end

    it "parse_upload_response returns [] for blank bodies and invalid JSON" do
      expect(filesystem.send(:parse_upload_response, "")).to eq([])
      expect(filesystem.send(:parse_upload_response, nil)).to eq([])
      expect(filesystem.send(:parse_upload_response, "{not json")).to eq([])
      expect(filesystem.send(:parse_upload_response, '[{"path":"/x"}]')).to eq([{ "path" => "/x" }])
    end

    it "build_write_info handles Hash, Array, and fallback shapes" do
      from_hash = filesystem.send(:build_write_info, { "path" => "/from-hash" }, default_path: "/d")
      expect(from_hash.path).to eq("/from-hash")

      from_array = filesystem.send(:build_write_info, [{ "path" => "/from-array" }], default_path: "/d")
      expect(from_array.path).to eq("/from-array")

      empty_array = filesystem.send(:build_write_info, [], default_path: "/default")
      expect(empty_array.path).to eq("/default")

      hash_without_path = filesystem.send(:build_write_info, {}, default_path: "/default")
      expect(hash_without_path.path).to eq("/default")

      nil_result = filesystem.send(:build_write_info, nil, default_path: "/default")
      expect(nil_result.path).to eq("/default")
    end
  end
end
