# frozen_string_literal: true

module E2B
  class DefaultBuildLogger
    DEFAULT_LEVEL = "info"
    LEVEL_ORDER = {
      "debug" => 0,
      "info" => 1,
      "warn" => 2,
      "error" => 3
    }.freeze

    def initialize(min_level: nil, io: $stdout)
      @min_level = min_level || DEFAULT_LEVEL
      @io = io
      @start_time = nil
    end

    def logger(log_entry)
      case log_entry
      when Models::TemplateLogEntryStart
        @start_time = Time.now
      when Models::TemplateLogEntryEnd
        @start_time = nil
      else
        return if LEVEL_ORDER.fetch(log_entry.level, LEVEL_ORDER[DEFAULT_LEVEL]) < LEVEL_ORDER[@min_level]

        @io.puts(format_log_line(log_entry))
      end
    end

    private

    def format_log_line(log_entry)
      elapsed = if @start_time
                  format("%0.1fs", Time.now - @start_time).ljust(5)
                else
                  "0.0s ".ljust(5)
                end
      timestamp = log_entry.timestamp&.strftime("%H:%M:%S")
      level = log_entry.level.upcase.ljust(5)
      "#{elapsed} | #{timestamp} #{level} #{log_entry.message}"
    end
  end

  class << self
    def default_build_logger(min_level: nil, io: $stdout)
      build_logger = DefaultBuildLogger.new(min_level: min_level, io: io)
      build_logger.method(:logger).to_proc
    end
  end
end
