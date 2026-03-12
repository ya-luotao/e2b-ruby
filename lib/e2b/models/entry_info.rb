# frozen_string_literal: true

require "time"

module E2B
  module Models
    # File types in the sandbox filesystem
    #
    # Maps to the protobuf FileType enum used by the filesystem service.
    #
    # @example
    #   entry.type == E2B::Models::FileType::FILE
    #   entry.type == E2B::Models::FileType::DIRECTORY
    module FileType
      # Regular file (FILE_TYPE_FILE = 1)
      FILE = "FILE"

      # Directory (FILE_TYPE_DIRECTORY = 2)
      DIRECTORY = "DIRECTORY"
    end

    # Filesystem event types from directory watching
    #
    # Maps to the protobuf EventType enum used by the filesystem watcher service.
    #
    # @example
    #   event.type == E2B::Models::FilesystemEventType::CREATE
    module FilesystemEventType
      # A new file or directory was created (EVENT_TYPE_CREATE = 1)
      CREATE = "CREATE"

      # A file was written to (EVENT_TYPE_WRITE = 2)
      WRITE = "WRITE"

      # A file or directory was removed (EVENT_TYPE_REMOVE = 3)
      REMOVE = "REMOVE"

      # A file or directory was renamed (EVENT_TYPE_RENAME = 4)
      RENAME = "RENAME"

      # File permissions were changed (EVENT_TYPE_CHMOD = 5)
      CHMOD = "CHMOD"
    end

    # Represents a filesystem event from directory watching
    #
    # Filesystem events are emitted when files or directories change within
    # a watched directory. Events are retrieved by polling via {WatchHandle#get_new_events}.
    #
    # @example
    #   events = watch_handle.get_new_events
    #   events.each do |event|
    #     puts "#{event.name} was #{event.type}"
    #   end
    class FilesystemEvent
      # @return [String] Name of the file or directory that changed
      attr_reader :name

      # @return [String] Type of event (one of {FilesystemEventType} constants)
      attr_reader :type

      # @param name [String] Name of the file or directory that changed
      # @param type [String] Type of event (one of {FilesystemEventType} constants)
      def initialize(name:, type:)
        @name = name
        @type = type
      end

      # Create from RPC response hash
      #
      # Handles both numeric protobuf enum values and string enum names.
      #
      # @param data [Hash] Raw event data from the RPC response
      # @return [FilesystemEvent]
      def self.from_hash(data)
        type_value = data["type"] || data[:type]
        type_name = case type_value
                    when 1, "EVENT_TYPE_CREATE" then FilesystemEventType::CREATE
                    when 2, "EVENT_TYPE_WRITE" then FilesystemEventType::WRITE
                    when 3, "EVENT_TYPE_REMOVE" then FilesystemEventType::REMOVE
                    when 4, "EVENT_TYPE_RENAME" then FilesystemEventType::RENAME
                    when 5, "EVENT_TYPE_CHMOD" then FilesystemEventType::CHMOD
                    else type_value.to_s
                    end
        new(name: data["name"] || data[:name], type: type_name)
      end
    end

    # Information about a filesystem entry (file or directory) in the sandbox
    #
    # Represents the protobuf EntryInfo message returned by filesystem RPCs
    # such as Stat, ListDir, and others. Contains metadata including name, type,
    # path, size, permissions, ownership, and modification time.
    #
    # @example
    #   entry = sandbox.files.stat("/home/user/hello.txt")
    #   puts entry.name          # => "hello.txt"
    #   puts entry.size          # => 13
    #   puts entry.file?         # => true
    #   puts entry.directory?    # => false
    #   puts entry.permissions   # => "0644"
    class EntryInfo
      # @return [String] Name of the file or directory
      attr_reader :name

      # @return [String] Type of entry (one of {FileType} constants)
      attr_reader :type

      # @return [String] Full path to the entry in the sandbox filesystem
      attr_reader :path

      # @return [Integer] Size in bytes
      attr_reader :size

      # @return [Integer] Unix file mode (e.g., 0o644)
      attr_reader :mode

      # @return [String] Permissions string (e.g., "0644")
      attr_reader :permissions

      # @return [String] Owner username
      attr_reader :owner

      # @return [String] Group name
      attr_reader :group

      # @return [Time, nil] Last modification time
      attr_reader :modified_time

      # @return [String, nil] Symlink target path, if the entry is a symlink
      attr_reader :symlink_target

      # @param name [String] Name of the file or directory
      # @param type [String] Type of entry (one of {FileType} constants)
      # @param path [String] Full path in the sandbox filesystem
      # @param size [Integer] Size in bytes
      # @param mode [Integer] Unix file mode
      # @param permissions [String] Permissions string
      # @param owner [String] Owner username
      # @param group [String] Group name
      # @param modified_time [Time, nil] Last modification time
      # @param symlink_target [String, nil] Symlink target path
      def initialize(name:, type:, path:, size: 0, mode: 0, permissions: "",
                     owner: "", group: "", modified_time: nil, symlink_target: nil)
        @name = name
        @type = type
        @path = path
        @size = size
        @mode = mode
        @permissions = permissions
        @owner = owner
        @group = group
        @modified_time = modified_time
        @symlink_target = symlink_target
      end

      # Check if this entry is a regular file
      #
      # @return [Boolean]
      def file?
        @type == FileType::FILE
      end

      # Check if this entry is a directory
      #
      # @return [Boolean]
      def directory?
        @type == FileType::DIRECTORY
      end

      # Create from RPC response hash
      #
      # Handles both numeric protobuf enum values and string enum names,
      # as well as camelCase and snake_case key formats.
      #
      # @param data [Hash] Raw entry data from the RPC response
      # @return [EntryInfo, nil] The parsed entry, or nil if data is not a Hash
      def self.from_hash(data)
        return nil unless data.is_a?(Hash)

        type_value = data["type"] || data[:type]
        type_name = case type_value
                    when 1, "FILE_TYPE_FILE" then FileType::FILE
                    when 2, "FILE_TYPE_DIRECTORY" then FileType::DIRECTORY
                    else type_value.to_s
                    end

        modified = data["modifiedTime"] || data["modified_time"] || data[:modifiedTime] || data[:modified_time]
        modified_time = parse_modified_time(modified)

        new(
          name: data["name"] || data[:name] || "",
          type: type_name,
          path: data["path"] || data[:path] || "",
          size: (data["size"] || data[:size] || 0).to_i,
          mode: (data["mode"] || data[:mode] || 0).to_i,
          permissions: data["permissions"] || data[:permissions] || "",
          owner: data["owner"] || data[:owner] || "",
          group: data["group"] || data[:group] || "",
          modified_time: modified_time,
          symlink_target: data["symlinkTarget"] || data["symlink_target"] || data[:symlinkTarget] || data[:symlink_target]
        )
      end

      # Parse a modified time value from various formats
      #
      # @param value [Hash, String, Time, nil] The raw modified time value
      # @return [Time, nil] Parsed time, or nil if unparseable
      def self.parse_modified_time(value)
        if value.is_a?(Hash)
          # Protobuf Timestamp format: { "seconds" => ..., "nanos" => ... }
          seconds = value["seconds"] || value[:seconds] || 0
          Time.at(seconds.to_i)
        elsif value.is_a?(String)
          Time.parse(value)
        elsif value.is_a?(Time)
          value
        end
      rescue ArgumentError
        nil
      end

      private_class_method :parse_modified_time
    end

    # Information about a file write operation
    #
    # Returned after writing a file to confirm the path that was written.
    #
    # @example
    #   info = sandbox.files.write("/home/user/output.txt", "content")
    #   puts info.path  # => "/home/user/output.txt"
    class WriteInfo
      # @return [String] Path of the written file
      attr_reader :path

      # @param path [String] Path of the written file
      def initialize(path:)
        @path = path
      end
    end
  end
end
