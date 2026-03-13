# frozen_string_literal: true

module E2B
  module Models
    class TemplateTagInfo
      attr_reader :build_id, :tags

      def self.from_hash(data)
        new(
          build_id: data["buildID"] || data["build_id"] || data[:buildID],
          tags: data["tags"] || data[:tags] || []
        )
      end

      def initialize(build_id:, tags:)
        @build_id = build_id
        @tags = tags || []
      end
    end
  end
end
