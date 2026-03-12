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
        @message = message
      end

      def self.parse_time(value)
        return nil if value.nil?
        return value if value.is_a?(Time)

        Time.parse(value)
      rescue ArgumentError
        nil
      end
    end
  end
end
