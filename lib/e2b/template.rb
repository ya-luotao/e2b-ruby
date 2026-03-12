# frozen_string_literal: true

require "digest"
require "json"
require "pathname"
require "uri"

module E2B
  class Template
    DEFAULT_BASE_IMAGE = "e2bdev/base"

    class << self
      def to_json(template, compute_hashes: false)
        template.to_json(compute_hashes: compute_hashes)
      end

      def to_dockerfile(template)
        template.to_dockerfile
      end

      def exists(name, api_key: nil, access_token: nil, domain: nil)
        alias_exists(name, api_key: api_key, access_token: access_token, domain: domain)
      end

      def alias_exists(alias_name, api_key: nil, access_token: nil, domain: nil)
        credentials = resolve_credentials(api_key: api_key, access_token: access_token)
        http_client = build_http_client(**credentials, domain: resolve_domain(domain))
        http_client.get("/templates/aliases/#{escape_path_segment(alias_name)}")
        true
      rescue E2B::NotFoundError
        false
      rescue E2B::AuthenticationError => e
        return true if e.status_code == 403

        raise
      end

      def assign_tags(target_name, tags, api_key: nil, access_token: nil, domain: nil)
        credentials = resolve_credentials(api_key: api_key, access_token: access_token)
        http_client = build_http_client(**credentials, domain: resolve_domain(domain))
        response = http_client.post("/templates/tags", body: {
          target: target_name,
          tags: normalize_tags(tags)
        })

        Models::TemplateTagInfo.from_hash(response)
      end

      def remove_tags(name, tags, api_key: nil, access_token: nil, domain: nil)
        credentials = resolve_credentials(api_key: api_key, access_token: access_token)
        http_client = build_http_client(**credentials, domain: resolve_domain(domain))
        http_client.delete("/templates/tags", body: {
          name: name,
          tags: normalize_tags(tags)
        })
        nil
      end

      def get_tags(template_id, api_key: nil, access_token: nil, domain: nil)
        credentials = resolve_credentials(api_key: api_key, access_token: access_token)
        http_client = build_http_client(**credentials, domain: resolve_domain(domain))
        response = http_client.get("/templates/#{escape_path_segment(template_id)}/tags")

        Array(response).map { |item| Models::TemplateTag.from_hash(item) }
      end

      def get_build_status(build_info = nil, logs_offset: nil, api_key: nil, access_token: nil, domain: nil,
                           template_id: nil, build_id: nil)
        resolved_template_id, resolved_build_id = extract_build_identifiers(
          build_info,
          template_id: template_id,
          build_id: build_id
        )

        credentials = resolve_credentials(api_key: api_key, access_token: access_token)
        http_client = build_http_client(**credentials, domain: resolve_domain(domain))
        params = {}
        params[:logsOffset] = logs_offset unless logs_offset.nil?

        response = http_client.get(
          "/templates/#{escape_path_segment(resolved_template_id)}/builds/#{escape_path_segment(resolved_build_id)}/status",
          params: params
        )

        Models::TemplateBuildStatusResponse.from_hash(response)
      end

      def wait_for_build_finish(build_info = nil, logs_offset: 0, on_build_logs: nil, logs_refresh_frequency: 0.2,
                                api_key: nil, access_token: nil, domain: nil, template_id: nil, build_id: nil)
        current_logs_offset = logs_offset

        loop do
          status = get_build_status(
            build_info,
            logs_offset: current_logs_offset,
            api_key: api_key,
            access_token: access_token,
            domain: domain,
            template_id: template_id,
            build_id: build_id
          )

          current_logs_offset += status.log_entries.length
          status.log_entries.each { |entry| on_build_logs.call(entry) } if on_build_logs

          case status.status
          when "building", "waiting"
            sleep_for_build_poll(logs_refresh_frequency)
          when "ready"
            return status
          when "error"
            raise BuildError, status.reason&.message || "Unknown build error occurred."
          else
            raise BuildError, "Unknown build status: #{status.status}"
          end
        end
      end

      private

      def normalize_tags(tags)
        Array(tags).flatten.compact
      end

      def extract_build_identifiers(build_info, template_id:, build_id:)
        if build_info
          if build_info.respond_to?(:template_id) && build_info.respond_to?(:build_id)
            return [build_info.template_id, build_info.build_id]
          end

          if build_info.is_a?(Hash)
            resolved_template_id = build_info[:template_id] || build_info["template_id"] ||
              build_info[:templateID] || build_info["templateID"]
            resolved_build_id = build_info[:build_id] || build_info["build_id"] ||
              build_info[:buildID] || build_info["buildID"]

            return [resolved_template_id, resolved_build_id]
          end
        end

        return [template_id, build_id] if template_id && build_id

        raise ArgumentError, "Provide build_info or both template_id: and build_id:"
      end

      def escape_path_segment(value)
        URI.encode_www_form_component(value.to_s)
      end

      def resolve_credentials(api_key:, access_token:)
        resolved_api_key = api_key || E2B.configuration&.api_key || ENV["E2B_API_KEY"]
        resolved_access_token = access_token || E2B.configuration&.access_token || ENV["E2B_ACCESS_TOKEN"]

        unless (resolved_api_key && !resolved_api_key.empty?) || (resolved_access_token && !resolved_access_token.empty?)
          raise ConfigurationError,
            "E2B credentials are required. Set E2B_API_KEY or E2B_ACCESS_TOKEN, or pass api_key:/access_token:."
        end

        { api_key: resolved_api_key, access_token: resolved_access_token }
      end

      def resolve_domain(domain)
        domain || E2B.configuration&.domain || ENV["E2B_DOMAIN"] || Configuration::DEFAULT_DOMAIN
      end

      def build_http_client(api_key:, access_token:, domain:)
        config = E2B.configuration
        base_url = config&.api_url || ENV["E2B_API_URL"] || Configuration.default_api_url(domain)
        API::HttpClient.new(
          base_url: base_url,
          api_key: api_key,
          access_token: access_token,
          logger: config&.logger
        )
      end

      def sleep_for_build_poll(interval)
        sleep(interval)
      end
    end

    def initialize(file_context_path: Dir.pwd, file_ignore_patterns: [])
      @file_context_path = file_context_path.to_s
      @file_ignore_patterns = Array(file_ignore_patterns)
      @base_image = DEFAULT_BASE_IMAGE
      @base_template = nil
      @registry_config = nil
      @start_cmd = nil
      @ready_cmd = nil
      @force = false
      @force_next_layer = false
      @instructions = []
    end

    def from_debian_image(variant = "stable")
      from_image("debian:#{variant}")
    end

    def from_ubuntu_image(variant = "latest")
      from_image("ubuntu:#{variant}")
    end

    def from_python_image(version = "3")
      from_image("python:#{version}")
    end

    def from_node_image(variant = "lts")
      from_image("node:#{variant}")
    end

    def from_bun_image(variant = "latest")
      from_image("oven/bun:#{variant}")
    end

    def from_base_image
      from_image(DEFAULT_BASE_IMAGE)
    end

    def from_image(image, username: nil, password: nil)
      @base_image = image
      @base_template = nil
      @registry_config = if username && password
                           {
                             type: "registry",
                             username: username,
                             password: password
                           }
                         end
      @force = true if @force_next_layer
      self
    end

    def from_template(template)
      @base_template = template
      @base_image = nil
      @registry_config = nil
      @force = true if @force_next_layer
      self
    end

    def copy(src, dest, force_upload: nil, user: nil, mode: nil, resolve_symlinks: nil)
      Array(src).each do |source|
        source_path = source.to_s
        validate_relative_path!(source_path)

        @instructions << {
          type: "COPY",
          args: [
            source_path,
            dest.to_s,
            user || "",
            mode ? format("%04o", mode) : ""
          ],
          force: !!force_upload || @force_next_layer,
          forceUpload: force_upload,
          resolveSymlinks: resolve_symlinks
        }
      end

      self
    end

    def run_cmd(cmd, user: nil)
      Array(cmd).each do |command|
        @instructions << {
          type: "RUN",
          args: [command.to_s, user || ""],
          force: @force_next_layer
        }
      end

      self
    end

    def set_workdir(workdir)
      @instructions << {
        type: "WORKDIR",
        args: [workdir.to_s],
        force: @force_next_layer
      }
      self
    end

    def set_user(user)
      @instructions << {
        type: "USER",
        args: [user.to_s],
        force: @force_next_layer
      }
      self
    end

    def set_envs(envs)
      args = envs.each_with_object([]) do |(key, value), values|
        values << key.to_s
        values << value.to_s
      end

      @instructions << {
        type: "ENV",
        args: args,
        force: @force_next_layer
      }
      self
    end

    def skip_cache
      @force_next_layer = true
      self
    end

    def set_start_cmd(start_cmd, ready_cmd = nil)
      @start_cmd = start_cmd.to_s
      @ready_cmd = ready_cmd.to_s unless ready_cmd.nil?
      self
    end

    def set_ready_cmd(ready_cmd)
      @ready_cmd = ready_cmd.to_s
      self
    end

    def to_h(compute_hashes: false)
      steps = compute_hashes ? instructions_with_hashes : serialized_steps(@instructions)
      template_data = {
        steps: steps,
        force: @force
      }
      template_data[:fromImage] = @base_image if @base_image
      template_data[:fromTemplate] = @base_template if @base_template
      template_data[:fromImageRegistry] = @registry_config if @registry_config
      template_data[:startCmd] = @start_cmd if @start_cmd
      template_data[:readyCmd] = @ready_cmd if @ready_cmd
      template_data
    end

    def to_json(compute_hashes: false)
      JSON.pretty_generate(to_h(compute_hashes: compute_hashes))
    end

    def to_dockerfile
      if @base_template
        raise TemplateError,
          "Cannot convert template built from another template to Dockerfile. Templates based on other templates can only be built using the E2B API."
      end

      raise TemplateError, "No base image specified for template" unless @base_image

      dockerfile = +"FROM #{@base_image}\n"
      @instructions.each do |instruction|
        case instruction[:type]
        when "RUN"
          dockerfile << "RUN #{instruction[:args][0]}\n"
        when "COPY"
          dockerfile << "COPY #{instruction[:args][0]} #{instruction[:args][1]}\n"
        when "ENV"
          values = instruction[:args].each_slice(2).map { |key, value| "#{key}=#{value}" }
          dockerfile << "ENV #{values.join(' ')}\n"
        else
          dockerfile << "#{instruction[:type]} #{instruction[:args].join(' ')}\n"
        end
      end
      dockerfile << "ENTRYPOINT #{@start_cmd}\n" if @start_cmd
      dockerfile
    end

    private

    def serialized_steps(steps)
      steps.map { |instruction| serialized_step(instruction) }
    end

    def instructions_with_hashes
      @instructions.map do |instruction|
        step = serialized_step(instruction)
        next step unless instruction[:type] == "COPY"

        src = instruction[:args][0]
        dest = instruction[:args][1]
        step[:filesHash] = calculate_files_hash(
          src,
          dest,
          resolve_symlinks: instruction[:resolveSymlinks].nil? ? true : instruction[:resolveSymlinks]
        )
        step
      end
    end

    def serialized_step(instruction)
      step = {
        type: instruction[:type],
        args: instruction[:args],
        force: instruction[:force]
      }
      step[:filesHash] = instruction[:filesHash] if instruction.key?(:filesHash)
      step[:forceUpload] = instruction[:forceUpload] unless instruction[:forceUpload].nil?
      step
    end

    def validate_relative_path!(src)
      if Pathname.new(src).absolute?
        raise TemplateError,
          "Invalid source path \"#{src}\": absolute paths are not allowed. Use a relative path within the context directory."
      end

      normalized = Pathname.new(src).cleanpath.to_s
      escapes = normalized == ".." || normalized.start_with?("../")
      return unless escapes

      raise TemplateError,
        "Invalid source path \"#{src}\": path escapes the context directory. The path must stay within the context directory."
    end

    def calculate_files_hash(src, dest, resolve_symlinks:)
      digest = Digest::SHA256.new
      digest.update("COPY #{src} #{dest}")
      files = collect_files(src)

      raise TemplateError, "No files found in #{File.join(@file_context_path, src)}" if files.empty?

      files.each do |file|
        relative_path = Pathname.new(file).relative_path_from(Pathname.new(@file_context_path)).to_s
        digest.update(relative_path)

        if File.symlink?(file)
          link_stat = File.lstat(file)
          should_follow = resolve_symlinks && (File.file?(file) || File.directory?(file))
          unless should_follow
            update_stat_hash(digest, link_stat)
            digest.update(File.readlink(file))
            next
          end
        end

        stat = File.stat(file)
        update_stat_hash(digest, stat)
        digest.update(File.binread(file)) if File.file?(file)
      end

      digest.hexdigest
    end

    def update_stat_hash(digest, stat)
      digest.update(stat.mode.to_s)
      digest.update(stat.size.to_s)
    end

    def collect_files(src)
      matches = Dir.glob(src, base: @file_context_path, flags: File::FNM_DOTMATCH)
        .reject { |entry| entry == "." || entry == ".." }

      files = []
      matches.each do |match|
        add_match_files(files, match)
      end

      files.uniq.sort
    end

    def add_match_files(files, match)
      full_path = File.join(@file_context_path, match)
      return if ignored_path?(match)

      if File.directory?(full_path) && !File.symlink?(full_path)
        files << full_path
        Dir.glob(File.join(full_path, "**", "*"), File::FNM_DOTMATCH).each do |child|
          next if [".", ".."].include?(File.basename(child))

          relative = Pathname.new(child).relative_path_from(Pathname.new(@file_context_path)).to_s
          next if ignored_path?(relative)

          files << child
        end
      else
        files << full_path
      end
    end

    def ignored_path?(relative_path)
      normalized = relative_path.tr(File::SEPARATOR, "/")
      ignore_patterns.any? do |pattern|
        File.fnmatch?(pattern, normalized, File::FNM_PATHNAME | File::FNM_DOTMATCH) ||
          File.fnmatch?(File.join(pattern, "**"), normalized, File::FNM_PATHNAME | File::FNM_DOTMATCH)
      end
    end

    def ignore_patterns
      @ignore_patterns ||= (@file_ignore_patterns + read_dockerignore).uniq
    end

    def read_dockerignore
      dockerignore_path = File.join(@file_context_path, ".dockerignore")
      return [] unless File.exist?(dockerignore_path)

      File.readlines(dockerignore_path, chomp: true)
        .map(&:strip)
        .reject { |line| line.empty? || line.start_with?("#") }
    end
  end
end
