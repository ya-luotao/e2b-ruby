# frozen_string_literal: true

module E2B
  module Models
    class BuildStatusReason
      attr_reader :message, :step, :log_entries

      def self.from_hash(data)
        return nil if data.nil?

        new(
          message: data["message"] || data[:message],
          step: data["step"] || data[:step],
          log_entries: Array(data["logEntries"] || data["log_entries"] || data[:logEntries]).map do |entry|
            TemplateLogEntry.from_hash(entry)
          end
        )
      end

      def initialize(message:, step: nil, log_entries: [])
        @message = message
        @step = step
        @log_entries = log_entries || []
      end
    end
  end
end
