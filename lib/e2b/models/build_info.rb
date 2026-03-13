# frozen_string_literal: true

module E2B
  module Models
    class BuildInfo
      attr_reader :alias_name, :name, :tags, :template_id, :build_id, :build_step_origins

      def self.from_hash(data)
        new(
          alias_name: data["alias"] || data[:alias],
          name: data["name"] || data[:name],
          tags: data["tags"] || data[:tags] || [],
          template_id: data["templateID"] || data["template_id"] || data[:templateID],
          build_id: data["buildID"] || data["build_id"] || data[:buildID],
          build_step_origins: data["buildStepOrigins"] || data["build_step_origins"] || data[:buildStepOrigins] || []
        )
      end

      def initialize(alias_name:, name:, tags:, template_id:, build_id:, build_step_origins: [])
        @alias_name = alias_name
        @name = name
        @tags = tags || []
        @template_id = template_id
        @build_id = build_id
        @build_step_origins = Array(build_step_origins).compact
      end
    end
  end
end
