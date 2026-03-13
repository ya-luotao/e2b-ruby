# frozen_string_literal: true

module E2B
  module Models
    class TemplateBuildStatusResponse
      attr_reader :build_id, :template_id, :status, :log_entries, :logs, :reason

      def self.from_hash(data)
        new(
          build_id: data["buildID"] || data["build_id"] || data[:buildID],
          template_id: data["templateID"] || data["template_id"] || data[:templateID],
          status: data["status"] || data[:status],
          log_entries: Array(data["logEntries"] || data["log_entries"] || data[:logEntries]).map do |entry|
            TemplateLogEntry.from_hash(entry)
          end,
          logs: data["logs"] || data[:logs] || [],
          reason: BuildStatusReason.from_hash(data["reason"] || data[:reason])
        )
      end

      def initialize(build_id:, template_id:, status:, log_entries:, logs:, reason:)
        @build_id = build_id
        @template_id = template_id
        @status = status
        @log_entries = log_entries || []
        @logs = logs || []
        @reason = reason
      end
    end
  end
end
