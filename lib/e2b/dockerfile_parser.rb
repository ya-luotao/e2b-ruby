# frozen_string_literal: true

require "json"
require "shellwords"

module E2B
  module DockerfileParser
    module_function

    def parse(dockerfile_content_or_path, template_builder)
      instructions = parse_instructions(read_dockerfile(dockerfile_content_or_path))
      from_instructions = instructions.select { |instruction| instruction[:keyword] == "FROM" }

      raise TemplateError, "Multi-stage Dockerfiles are not supported" if from_instructions.length > 1
      raise TemplateError, "Dockerfile must contain a FROM instruction" if from_instructions.empty?

      base_image = normalize_base_image(from_instructions.first[:value])
      user_changed = false
      workdir_changed = false

      template_builder.set_user("root")
      template_builder.set_workdir("/")

      instructions.each do |instruction|
        keyword = instruction[:keyword]
        value = instruction[:value]

        case keyword
        when "FROM"
          next
        when "RUN"
          handle_run(value, template_builder)
        when "COPY", "ADD"
          handle_copy(value, template_builder)
        when "WORKDIR"
          handle_workdir(value, template_builder)
          workdir_changed = true
        when "USER"
          handle_user(value, template_builder)
          user_changed = true
        when "ENV", "ARG"
          handle_env(value, keyword, template_builder)
        when "CMD", "ENTRYPOINT"
          handle_cmd(value, template_builder)
        end
      end

      template_builder.set_user("user") unless user_changed
      template_builder.set_workdir("/home/user") unless workdir_changed

      base_image
    end

    def read_dockerfile(dockerfile_content_or_path)
      if File.file?(dockerfile_content_or_path)
        File.read(dockerfile_content_or_path)
      else
        dockerfile_content_or_path
      end
    rescue StandardError
      dockerfile_content_or_path
    end

    def parse_instructions(content)
      instructions = []
      current = +""

      content.each_line do |raw_line|
        line = raw_line.chomp
        next if line.strip.empty? || line.lstrip.start_with?("#")

        if line.rstrip.end_with?("\\")
          current << line.rstrip.sub(/\\\s*\z/, "")
          current << " "
          next
        end

        current << line
        instruction = current.strip
        current = +""
        next if instruction.empty?

        keyword, value = instruction.split(/\s+/, 2)
        instructions << { keyword: keyword.upcase, value: value.to_s.strip }
      end

      unless current.strip.empty?
        keyword, value = current.strip.split(/\s+/, 2)
        instructions << { keyword: keyword.upcase, value: value.to_s.strip }
      end

      instructions
    end

    def normalize_base_image(value)
      value.sub(/\s+as\s+.+\z/i, "").strip
    end

    def handle_run(value, template_builder)
      return if value.strip.empty?

      template_builder.run_cmd(value.strip.gsub(/\s+/, " "))
    end

    def handle_copy(value, template_builder)
      return if value.strip.empty?

      parts = Shellwords.split(value)
      user = nil
      non_flag_parts = []

      parts.each do |part|
        if part.start_with?("--chown=")
          user = part.delete_prefix("--chown=")
        elsif !part.start_with?("--")
          non_flag_parts << part
        end
      end

      return unless non_flag_parts.length >= 2

      src = non_flag_parts.first
      dest = non_flag_parts.last
      template_builder.copy(src, dest, user: user)
    end

    def handle_workdir(value, template_builder)
      return if value.strip.empty?

      template_builder.set_workdir(value.strip)
    end

    def handle_user(value, template_builder)
      return if value.strip.empty?

      template_builder.set_user(value.strip)
    end

    def handle_env(value, keyword, template_builder)
      return if value.strip.empty?

      parts = Shellwords.split(value)
      envs = {}

      if parts.length == 1
        parse_single_env_part(parts.first, keyword, envs)
      elsif parts.length == 2 && !(parts[0].include?("=") && parts[1].include?("="))
        envs[parts[0]] = parts[1]
      else
        parts.each { |part| parse_single_env_part(part, keyword, envs) }
      end

      template_builder.set_envs(envs) unless envs.empty?
    end

    def parse_single_env_part(part, keyword, envs)
      equal_index = part.index("=")
      if equal_index && equal_index.positive?
        envs[part[0...equal_index]] = part[(equal_index + 1)..]
      elsif keyword == "ARG" && !part.strip.empty?
        envs[part.strip] = ""
      end
    end

    def handle_cmd(value, template_builder)
      return if value.strip.empty?

      command = value.strip
      begin
        parsed = JSON.parse(command)
        command = parsed.join(" ") if parsed.is_a?(Array)
      rescue JSON::ParserError
        nil
      end

      template_builder.set_start_cmd(command, E2B.wait_for_timeout(20_000))
    end
  end
end
