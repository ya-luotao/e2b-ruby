# frozen_string_literal: true

require "spec_helper"
require "stringio"
require "time"

RSpec.describe E2B::DefaultBuildLogger do
  let(:io) { StringIO.new }

  def entry(level:, message:, timestamp: Time.utc(2026, 1, 1, 12, 0, 0))
    E2B::Models::TemplateLogEntry.new(timestamp: timestamp, level: level, message: message)
  end

  it "writes entries at or above the minimum level" do
    logger = described_class.new(min_level: "info", io: io)
    logger.logger(entry(level: "info", message: "shown"))

    expect(io.string).to include("shown")
    expect(io.string).to include("INFO")
    expect(io.string).to include("12:00:00")
  end

  it "filters out entries below the minimum level" do
    logger = described_class.new(min_level: "warn", io: io)
    logger.logger(entry(level: "info", message: "hidden"))

    expect(io.string).to be_empty
  end

  it "tracks elapsed time using start/end marker entries" do
    logger = described_class.new(min_level: "debug", io: io)

    logger.logger(E2B::Models::TemplateLogEntryStart.new(timestamp: Time.now, message: "start"))
    logger.logger(entry(level: "info", message: "during build"))
    logger.logger(E2B::Models::TemplateLogEntryEnd.new(timestamp: Time.now, message: "end"))

    # The Start/End markers themselves are not printed; only the info line is.
    expect(io.string.lines.count).to eq(1)
    expect(io.string).to match(/\d+\.\ds/)
  end

  it "defaults the minimum level to info" do
    logger = described_class.new(io: io)
    logger.logger(entry(level: "debug", message: "hidden"))
    logger.logger(entry(level: "error", message: "shown"))

    expect(io.string).to include("shown")
    expect(io.string).not_to include("hidden")
  end

  describe "E2B.default_build_logger" do
    it "returns a callable proc that logs entries" do
      io = StringIO.new
      callback = E2B.default_build_logger(min_level: "debug", io: io)

      callback.call(E2B::Models::TemplateLogEntry.new(timestamp: Time.now, level: "info", message: "via proc"))

      expect(callback).to respond_to(:call)
      expect(io.string).to include("via proc")
    end
  end
end
