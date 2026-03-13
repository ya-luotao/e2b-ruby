# frozen_string_literal: true

require "time"

module E2B
  module Models
    class TemplateTag
      attr_reader :tag, :build_id, :created_at

      def self.from_hash(data)
        new(
          tag: data["tag"] || data[:tag],
          build_id: data["buildID"] || data["build_id"] || data[:buildID],
          created_at: parse_time(data["createdAt"] || data["created_at"] || data[:createdAt])
        )
      end

      def initialize(tag:, build_id:, created_at:)
        @tag = tag
        @build_id = build_id
        @created_at = created_at
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
