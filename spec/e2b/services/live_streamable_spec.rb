# frozen_string_literal: true

require "spec_helper"

RSpec.describe E2B::Services::LiveStreamable do
  # build_live_handle is exercised end-to-end through Commands#run/#connect.
  # These specs pin the helper's event-parsing edge cases directly.
  let(:host_class) do
    Class.new do
      include E2B::Services::LiveStreamable

      public(*E2B::Services::LiveStreamable.private_instance_methods)
    end
  end
  let(:host) { host_class.new }

  describe "#extract_pid_from_event" do
    it "extracts the pid from a Start event (PascalCase)" do
      expect(host.extract_pid_from_event("event" => { "Start" => { "pid" => 99 } })).to eq(99)
    end

    it "extracts the pid from a start event (lowercase)" do
      expect(host.extract_pid_from_event("event" => { "start" => { "pid" => "42" } })).to eq(42)
    end

    it "returns nil for non-start events and malformed input" do
      expect(host.extract_pid_from_event("event" => { "Data" => {} })).to be_nil
      expect(host.extract_pid_from_event("event" => {})).to be_nil
      expect(host.extract_pid_from_event({})).to be_nil
      expect(host.extract_pid_from_event(nil)).to be_nil
      expect(host.extract_pid_from_event("not a hash")).to be_nil
    end
  end

  describe "#disconnect_live_stream" do
    it "closes the stream discarding pending events and kills a live thread" do
      stream = E2B::Services::LiveEventStream.new
      thread = instance_double(Thread, alive?: true)
      allow(thread).to receive(:kill)

      host.disconnect_live_stream(thread, stream)

      expect(thread).to have_received(:kill)
      # A closed stream yields nothing further.
      expect(stream.each.to_a).to be_empty
    end

    it "does not kill a thread that has already finished" do
      stream = E2B::Services::LiveEventStream.new
      thread = instance_double(Thread, alive?: false)

      expect { host.disconnect_live_stream(thread, stream) }.not_to raise_error
    end
  end
end
