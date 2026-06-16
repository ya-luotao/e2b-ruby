# frozen_string_literal: true

require "spec_helper"

RSpec.describe E2B::Services::WatchHandle do
  let(:rpc_calls) { [] }
  let(:rpc_response) { { "events" => [] } }
  let(:envd_rpc_proc) do
    lambda do |service, method, body:, headers:|
      rpc_calls << { service: service, method: method, body: body, headers: headers }
      rpc_response
    end
  end
  let(:handle) do
    described_class.new(watcher_id: "w1", envd_rpc_proc: envd_rpc_proc, headers: { "Authorization" => "Basic x" })
  end

  describe "#get_new_events" do
    it "polls GetWatcherEvents and maps results to FilesystemEvent" do
      stub_response = { "events" => [{ "name" => "a.txt", "type" => 1 }] }
      allow(envd_rpc_proc).to receive(:call).and_return(stub_response)

      handle = described_class.new(watcher_id: "w1", envd_rpc_proc: envd_rpc_proc)
      events = handle.get_new_events

      expect(events.first).to be_a(E2B::Models::FilesystemEvent)
      expect(events.first.name).to eq("a.txt")
      expect(events.first.type).to eq(E2B::Models::FilesystemEventType::CREATE)
    end

    it "sends the watcher id and headers to the RPC" do
      handle.get_new_events

      call = rpc_calls.last
      expect(call[:service]).to eq("filesystem.Filesystem")
      expect(call[:method]).to eq("GetWatcherEvents")
      expect(call[:body]).to eq(watcherId: "w1")
      expect(call[:headers]).to eq("Authorization" => "Basic x")
    end

    it "returns an empty array when the response has no events key" do
      allow(envd_rpc_proc).to receive(:call).and_return({})
      handle = described_class.new(watcher_id: "w1", envd_rpc_proc: envd_rpc_proc)
      expect(handle.get_new_events).to eq([])
    end

    it "raises once the watcher has been stopped" do
      handle.stop
      expect { handle.get_new_events }.to raise_error(E2B::E2BError, /stopped/)
    end
  end

  describe "#stop" do
    it "calls RemoveWatcher and marks the handle stopped" do
      handle.stop

      expect(rpc_calls.last[:method]).to eq("RemoveWatcher")
      expect(rpc_calls.last[:body]).to eq(watcherId: "w1")
      expect(handle).to be_stopped
    end

    it "is a no-op when already stopped (only one RemoveWatcher call)" do
      handle.stop
      handle.stop
      expect(rpc_calls.count { |c| c[:method] == "RemoveWatcher" }).to eq(1)
    end

    it "swallows cleanup errors and still marks the handle stopped" do
      allow(envd_rpc_proc).to receive(:call).and_raise(E2B::E2BError, "already gone")
      handle = described_class.new(watcher_id: "w1", envd_rpc_proc: envd_rpc_proc)

      expect { handle.stop }.not_to raise_error
      expect(handle).to be_stopped
    end
  end
end
