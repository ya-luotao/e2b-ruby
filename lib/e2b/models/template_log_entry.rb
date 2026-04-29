# frozen_string_literal: true

require "time"

module E2B
  module Models
    class TemplateLogEntry
      attr_reader :timestamp, :level, :message

      def self.from_hash(data)
        new(
          timestamp: parse_time(data["timestamp"] || data[:timestamp]),
          level: data["level"] || data[:level],
          message: data["message"] || data[:message]
        )
      end

      def initialize(timestamp:, level:, message:)
        @timestamp = timestamp
        @level = level
        @message = self.class.strip_ansi_escape_codes(message.to_s)
      end

      def to_s
        "[#{@timestamp&.iso8601}] [#{@level}] #{@message}"
      end

      def self.parse_time(value)
        return nil if value.nil?
        return value if value.is_a?(Time)

        Time.parse(value.to_s)
      rescue ArgumentError, TypeError
        nil
      end

      def self.strip_ansi_escape_codes(message)
        message.gsub(/\e\[[0-9;?]*[ -\/]*[@-~]/, "")
      end
    end

    class TemplateLogEntryStart < TemplateLogEntry
      def initialize(timestamp:, message:)
        super(timestamp: timestamp, level: "debug", message: message)
      end
    end

    class TemplateLogEntryEnd < TemplateLogEntry
      def initialize(timestamp:, message:)
        super(timestamp: timestamp, level: "debug", message: message)
      end
    end
  end
end
