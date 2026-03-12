# frozen_string_literal: true

require "digest"
require "json"
require "pathname"
require "rubygems/package"
require "stringio"
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

      def build(template, name: nil, alias_name: nil, tags: nil, cpu_count: 2, memory_mb: 1024, skip_cache: false,
                on_build_logs: nil, api_key: nil, access_token: nil, domain: nil)
        build_info = build_in_background(
          template,
          name: name,
          alias_name: alias_name,
          tags: tags,
          cpu_count: cpu_count,
          memory_mb: memory_mb,
          skip_cache: skip_cache,
          on_build_logs: on_build_logs,
          api_key: api_key,
          access_token: access_token,
          domain: domain
        )

        on_build_logs&.call(log_entry("Waiting for logs..."))

        wait_for_build_finish(
          build_info,
          on_build_logs: on_build_logs,
          api_key: api_key,
          access_token: access_token,
          domain: domain
        )

        build_info
      end

      def build_in_background(template, name: nil, alias_name: nil, tags: nil, cpu_count: 2, memory_mb: 1024,
                              skip_cache: false, on_build_logs: nil, api_key: nil, access_token: nil, domain: nil)
        resolved_name = normalize_build_name(name: name, alias_name: alias_name)
        template.send(:force_build!) if skip_cache

        credentials = resolve_credentials(api_key: api_key, access_token: access_token)
        http_client = build_http_client(**credentials, domain: resolve_domain(domain))

        tags_message = Array(tags).any? ? " with tags #{Array(tags).join(', ')}" : ""
        on_build_logs&.call(log_entry("Requesting build for template: #{resolved_name}#{tags_message}"))

        create_response = http_client.post("/v3/templates", body: {
          name: resolved_name,
          tags: tags,
          cpuCount: cpu_count,
          memoryMB: memory_mb
        })

        build_info = Models::BuildInfo.new(
          alias_name: resolved_name,
          name: resolved_name,
          tags: create_response["tags"] || create_response[:tags] || [],
          template_id: create_response["templateID"] || create_response[:templateID],
          build_id: create_response["buildID"] || create_response[:buildID]
        )

        on_build_logs&.call(
          log_entry("Template created with ID: #{build_info.template_id}, Build ID: #{build_info.build_id}")
        )

        instructions = template.send(:instructions_with_hash_metadata)
        upload_copy_instructions(
          http_client,
          template,
          build_info,
          instructions,
          on_build_logs: on_build_logs
        )

        on_build_logs&.call(log_entry("All file uploads completed"))
        on_build_logs&.call(log_entry("Starting building..."))

        http_client.post(
          "/v2/templates/#{escape_path_segment(build_info.template_id)}/builds/#{escape_path_segment(build_info.build_id)}",
          body: template.send(:build_payload, instructions)
        )

        build_info
      end

      private

      def normalize_build_name(name:, alias_name:)
        resolved_name = name || alias_name
        return resolved_name if resolved_name && !resolved_name.empty?

        raise TemplateError, "Name must be provided"
      end

      def upload_copy_instructions(http_client, template, build_info, instructions, on_build_logs:)
        instructions.each do |instruction|
          next unless instruction[:type] == "COPY"

          src = instruction[:args][0]
          files_hash = instruction[:filesHash]
          response = http_client.get(
            "/templates/#{escape_path_segment(build_info.template_id)}/files/#{escape_path_segment(files_hash)}"
          )
          present = response["present"]
          url = response["url"]

          if (instruction[:forceUpload] && url) || (present == false && url)
            upload_file(
              template,
              file_name: src,
              url: url,
              resolve_symlinks: instruction[:resolveSymlinks].nil? ? true : instruction[:resolveSymlinks]
            )
            on_build_logs&.call(log_entry("Uploaded '#{src}'"))
          else
            on_build_logs&.call(log_entry("Skipping upload of '#{src}', already cached"))
          end
        end
      end

      def upload_file(template, file_name:, url:, resolve_symlinks:)
        tarball = build_tar_archive(template, file_name, resolve_symlinks: resolve_symlinks)
        response = Faraday.put(url) do |req|
          req.headers["Content-Type"] = "application/octet-stream"
          req.body = tarball
        end

        return if response.success?

        raise BuildError, "Failed to upload file: #{response.status}"
      rescue Faraday::Error => e
        raise BuildError, "Failed to upload file: #{e.message}"
      end

      def build_tar_archive(template, file_name, resolve_symlinks:)
        context_path = template.send(:file_context_path)
        files = template.send(:collect_files, file_name)
        output = StringIO.new

        Gem::Package::TarWriter.new(output) do |tar|
          files.each do |file|
            relative = Pathname.new(file).relative_path_from(Pathname.new(context_path)).to_s

            if File.symlink?(file) && !resolve_symlinks
              tar.add_symlink(relative, File.readlink(file), File.lstat(file).mode)
              next
            end

            stat = File.stat(file)
            if File.directory?(file)
              tar.mkdir(relative, stat.mode)
            elsif File.file?(file)
              tar.add_file_simple(relative, stat.mode, stat.size) do |io|
                io.write(File.binread(file))
              end
            end
          end
        end

        output.rewind
        output.string
      end

      def log_entry(message, level = "info")
        Models::TemplateLogEntry.new(
          timestamp: Time.now,
          level: level,
          message: message
        )
      end

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

    def from_aws_registry(image, access_key_id:, secret_access_key:, region:)
      @base_image = image
      @base_template = nil
      @registry_config = {
        type: "aws",
        awsAccessKeyId: access_key_id,
        awsSecretAccessKey: secret_access_key,
        awsRegion: region
      }
      @force = true if @force_next_layer
      self
    end

    def from_gcp_registry(image, service_account_json:)
      @base_image = image
      @base_template = nil
      @registry_config = {
        type: "gcp",
        serviceAccountJson: read_gcp_service_account_json(service_account_json)
      }
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

    def copy_items(items)
      items.each do |item|
        copy(
          copy_item_value(item, :src),
          copy_item_value(item, :dest),
          force_upload: copy_item_value(item, :forceUpload, required: false),
          user: copy_item_value(item, :user, required: false),
          mode: copy_item_value(item, :mode, required: false),
          resolve_symlinks: copy_item_value(item, :resolveSymlinks, required: false)
        )
      end

      self
    end

    def run_cmd(cmd, user: nil)
      commands = Array(cmd).map(&:to_s)

      @instructions << {
        type: "RUN",
        args: [commands.join(" && "), user || ""],
        force: @force_next_layer
      }

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
      return self if envs.empty?

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

    def pip_install(packages = nil, g: true)
      package_list = packages.nil? ? nil : Array(packages).map(&:to_s)
      args = ["pip", "install"]
      args << "--user" unless g
      args.concat(package_list || ["."])
      run_cmd(args.join(" "), user: g ? "root" : nil)
    end

    def npm_install(packages = nil, g: false, dev: false)
      package_list = packages.nil? ? nil : Array(packages).map(&:to_s)
      args = ["npm", "install"]
      args << "-g" if g
      args << "--save-dev" if dev
      args.concat(package_list) if package_list
      run_cmd(args.join(" "), user: g ? "root" : nil)
    end

    def bun_install(packages = nil, g: false, dev: false)
      package_list = packages.nil? ? nil : Array(packages).map(&:to_s)
      args = ["bun", "install"]
      args << "-g" if g
      args << "--dev" if dev
      args.concat(package_list) if package_list
      run_cmd(args.join(" "), user: g ? "root" : nil)
    end

    def apt_install(packages, no_install_recommends: false)
      package_list = Array(packages).map(&:to_s)
      install_flags = no_install_recommends ? "--no-install-recommends " : ""
      run_cmd(
        [
          "apt-get update",
          "DEBIAN_FRONTEND=noninteractive DEBCONF_NOWARNINGS=yes apt-get install -y #{install_flags}#{package_list.join(' ')}"
        ],
        user: "root"
      )
    end

    def add_mcp_server(servers)
      raise BuildError, "MCP servers can only be added to mcp-gateway template" unless @base_template == "mcp-gateway"

      server_list = Array(servers).map(&:to_s)
      run_cmd("mcp-gateway pull #{server_list.join(' ')}", user: "root")
    end

    def git_clone(url, path = nil, branch: nil, depth: nil, user: nil)
      args = ["git", "clone", url.to_s]
      if branch
        args << "--branch #{branch}"
        args << "--single-branch"
      end
      args << "--depth #{depth}" if depth
      args << path.to_s if path
      run_cmd(args.join(" "), user: user)
    end

    def beta_dev_container_prebuild(devcontainer_directory)
      ensure_devcontainer_template!
      run_cmd("devcontainer build --workspace-folder #{devcontainer_directory}", user: "root")
    end

    def beta_set_dev_container_start(devcontainer_directory)
      ensure_devcontainer_template!
      set_start_cmd(
        "sudo devcontainer up --workspace-folder #{devcontainer_directory} && sudo /prepare-exec.sh #{devcontainer_directory} | sudo tee /devcontainer.sh > /dev/null && sudo chmod +x /devcontainer.sh && sudo touch /devcontainer.up",
        "test -f /devcontainer.up"
      )
    end

    alias beta_set_devcontainer_start beta_set_dev_container_start

    def remove(path, force: false, recursive: false, user: nil)
      args = ["rm"]
      args << "-r" if recursive
      args << "-f" if force
      args.concat(Array(path).map(&:to_s))
      run_cmd(args.join(" "), user: user)
    end

    def rename(src, dest, force: false, user: nil)
      args = ["mv"]
      args << "-f" if force
      args << src.to_s
      args << dest.to_s
      run_cmd(args.join(" "), user: user)
    end

    def make_dir(path, mode: nil, user: nil)
      args = ["mkdir", "-p"]
      args << "-m #{format('%04o', mode)}" if mode
      args.concat(Array(path).map(&:to_s))
      run_cmd(args.join(" "), user: user)
    end

    def make_symlink(src, dest, user: nil, force: false)
      args = ["ln", "-s"]
      args << "-f" if force
      args << src.to_s
      args << dest.to_s
      run_cmd(args.join(" "), user: user)
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
      build_payload(compute_hashes ? instructions_with_hash_metadata : @instructions)
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

    protected

    attr_reader :file_context_path

    private

    def force_build!
      @force = true
    end

    def build_payload(instructions)
      template_data = {
        steps: serialized_steps(instructions),
        force: @force
      }
      template_data[:fromImage] = @base_image if @base_image
      template_data[:fromTemplate] = @base_template if @base_template
      template_data[:fromImageRegistry] = @registry_config if @registry_config
      template_data[:startCmd] = @start_cmd if @start_cmd
      template_data[:readyCmd] = @ready_cmd if @ready_cmd
      template_data
    end

    def serialized_steps(steps)
      steps.map { |instruction| serialized_step(instruction) }
    end

    def instructions_with_hashes
      serialized_steps(instructions_with_hash_metadata)
    end

    def instructions_with_hash_metadata
      @instructions.map do |instruction|
        next instruction unless instruction[:type] == "COPY"

        src = instruction[:args][0]
        dest = instruction[:args][1]
        instruction.merge(filesHash: calculate_files_hash(
          src,
          dest,
          resolve_symlinks: instruction[:resolveSymlinks].nil? ? true : instruction[:resolveSymlinks]
        ))
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

    def read_gcp_service_account_json(path_or_content)
      return JSON.generate(path_or_content) unless path_or_content.is_a?(String)

      File.read(File.join(@file_context_path, path_or_content))
    end

    def copy_item_value(item, key, required: true)
      value = item[key]
      value = item[key.to_s] if value.nil?
      return value unless value.nil? && required

      raise KeyError, "Missing copy_items value for #{key}"
    end

    def ensure_devcontainer_template!
      return if @base_template == "devcontainer"

      raise BuildError, "Devcontainers can only used in the devcontainer template"
    end
  end
end
