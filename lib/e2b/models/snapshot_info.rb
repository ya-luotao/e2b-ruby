# frozen_string_literal: true

module E2B
  module Models
    class SnapshotInfo
      attr_reader :snapshot_id

      def self.from_hash(data)
        new(
          snapshot_id: data["snapshotID"] || data["snapshot_id"] || data[:snapshotID]
        )
      end

      def initialize(snapshot_id:)
        @snapshot_id = snapshot_id
      end
    end
  end
end
