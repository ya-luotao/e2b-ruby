# frozen_string_literal: true

require "spec_helper"
require "stringio"
require "tmpdir"

RSpec.describe E2B::Template do
  let(:http_client) { instance_double(E2B::API::HttpClient) }

  before do
    allow(ENV).to receive(:[]).and_call_original
    %w[E2B_API_KEY E2B_ACCESS_TOKEN E2B_API_URL E2B_DOMAIN E2B_DEBUG].each do |name|
      allow(ENV).to receive(:[]).with(name).and_return(nil)
    end
    allow(E2B::API::HttpClient).to receive(:new).and_return(http_client)
  end

  describe ".exists" do
    it "returns false when the template alias does not exist" do
      allow(http_client).to receive(:get).with("/templates/aliases/missing-template").and_raise(
        E2B::NotFoundError.new("missing", status_code: 404)
      )

      expect(described_class.exists("missing-template", api_key: "api-key")).to be(false)
    end

    it "returns true when the alias exists but belongs to another team" do
      allow(http_client).to receive(:get).with("/templates/aliases/team-template").and_raise(
        E2B::AuthenticationError.new("forbidden", status_code: 403)
      )

      expect(described_class.alias_exists("team-template", api_key: "api-key")).to be(true)
    end
  end

  describe ".assign_tags" do
    it "normalizes tags and returns tag info" do
      allow(http_client).to receive(:post)
        .with(
          "/templates/tags",
          body: {
            target: "my-template:v1",
            tags: ["stable"]
          }
        )
        .and_return({
          "buildID" => "bld_123",
          "tags" => ["stable"]
        })

      response = described_class.assign_tags("my-template:v1", "stable", api_key: "api-key")

      expect(response).to be_a(E2B::Models::TemplateTagInfo)
      expect(response.build_id).to eq("bld_123")
      expect(response.tags).to eq(["stable"])
    end
  end

  describe ".remove_tags" do
    it "sends a delete request with a JSON body" do
      expect(http_client).to receive(:delete)
        .with(
          "/templates/tags",
          body: {
            name: "my-template",
            tags: %w[stable prod]
          }
        )

      expect(
        described_class.remove_tags("my-template", %w[stable prod], api_key: "api-key")
      ).to be_nil
    end
  end

  describe ".get_tags" do
    it "returns parsed template tags and escapes template names in the path" do
      allow(http_client).to receive(:get)
        .with("/templates/my-template%3Alatest/tags")
        .and_return([
          {
            "tag" => "stable",
            "buildID" => "bld_123",
            "createdAt" => "2026-03-13T09:00:00Z"
          }
        ])

      tags = described_class.get_tags("my-template:latest", api_key: "api-key")

      expect(tags.length).to eq(1)
      expect(tags.first).to be_a(E2B::Models::TemplateTag)
      expect(tags.first.tag).to eq("stable")
      expect(tags.first.build_id).to eq("bld_123")
      expect(tags.first.created_at).to eq(Time.parse("2026-03-13T09:00:00Z"))
    end
  end

  describe ".get_build_status" do
    it "hydrates build status responses from build info hashes" do
      allow(http_client).to receive(:get)
        .with(
          "/templates/tpl_123/builds/bld_123/status",
          params: { logsOffset: 2 }
        )
        .and_return({
          "buildID" => "bld_123",
          "templateID" => "tpl_123",
          "status" => "building",
          "logs" => ["raw log"],
          "logEntries" => [
            {
              "timestamp" => "2026-03-13T09:00:00Z",
              "level" => "info",
              "message" => "Uploading"
            }
          ],
          "reason" => {
            "message" => "waiting on cache",
            "step" => "COPY",
            "logEntries" => [
              {
                "timestamp" => "2026-03-13T09:00:01Z",
                "level" => "info",
                "message" => "Cached"
              }
            ]
          }
        })

      status = described_class.get_build_status(
        { template_id: "tpl_123", build_id: "bld_123" },
        logs_offset: 2,
        api_key: "api-key"
      )

      expect(status).to be_a(E2B::Models::TemplateBuildStatusResponse)
      expect(status.status).to eq("building")
      expect(status.log_entries.map(&:message)).to eq(["Uploading"])
      expect(status.reason.message).to eq("waiting on cache")
      expect(status.reason.log_entries.map(&:message)).to eq(["Cached"])
    end
  end

  describe ".wait_for_build_finish" do
    let(:build_info) do
      E2B::Models::BuildInfo.new(
        alias_name: "my-template",
        name: "my-template",
        tags: ["stable"],
        template_id: "tpl_123",
        build_id: "bld_123"
      )
    end

    it "polls until the build is ready and yields fresh log entries" do
      first_status = E2B::Models::TemplateBuildStatusResponse.new(
        build_id: "bld_123",
        template_id: "tpl_123",
        status: "building",
        logs: [],
        reason: nil,
        log_entries: [
          E2B::Models::TemplateLogEntry.new(
            timestamp: Time.parse("2026-03-13T09:00:00Z"),
            level: "info",
            message: "Starting"
          )
        ]
      )
      final_status = E2B::Models::TemplateBuildStatusResponse.new(
        build_id: "bld_123",
        template_id: "tpl_123",
        status: "ready",
        logs: [],
        reason: nil,
        log_entries: [
          E2B::Models::TemplateLogEntry.new(
            timestamp: Time.parse("2026-03-13T09:00:01Z"),
            level: "info",
            message: "Done"
          )
        ]
      )

      allow(described_class).to receive(:get_build_status).and_return(first_status, final_status)
      allow(described_class).to receive(:sleep_for_build_poll)

      yielded_messages = []
      result = described_class.wait_for_build_finish(
        build_info,
        api_key: "api-key",
        on_build_logs: ->(entry) { yielded_messages << entry.message }
      )

      expect(result).to eq(final_status)
      expect(yielded_messages).to eq(%w[Starting Done])
      expect(described_class).to have_received(:sleep_for_build_poll).with(0.2).once
    end

    it "raises BuildError when the build returns an error status" do
      error_status = E2B::Models::TemplateBuildStatusResponse.new(
        build_id: "bld_123",
        template_id: "tpl_123",
        status: "error",
        logs: [],
        log_entries: [],
        reason: E2B::Models::BuildStatusReason.new(message: "Build failed")
      )

      allow(described_class).to receive(:get_build_status).and_return(error_status)

      expect {
        described_class.wait_for_build_finish(build_info, api_key: "api-key")
      }.to raise_error(E2B::BuildError, "Build failed")
    end
  end

  describe "ready command helpers" do
    it "builds helper commands and accepts ReadyCmd values in template start commands" do
      template = described_class.new
        .from_base_image
        .set_start_cmd("bundle exec ruby app.rb", E2B.wait_for_file("/tmp/ready"))

      expect(E2B.wait_for_port(8080).get_cmd).to eq("ss -tuln | grep :8080")
      expect(E2B.wait_for_url("http://localhost:3000/health", 204).get_cmd)
        .to eq('curl -s -o /dev/null -w "%{http_code}" http://localhost:3000/health | grep -q "204"')
      expect(E2B.wait_for_process("nginx").get_cmd).to eq("pgrep nginx > /dev/null")
      expect(E2B.wait_for_timeout(5000).get_cmd).to eq("sleep 5")
      expect(template.to_h[:readyCmd]).to eq("[ -f /tmp/ready ]")
    end
  end

  describe "build logger helpers" do
    it "strips ansi sequences from template log entries" do
      entry = E2B::Models::TemplateLogEntry.new(
        timestamp: Time.parse("2026-03-13T09:00:00Z"),
        level: "info",
        message: "\e[31mHello\e[0m"
      )

      expect(entry.message).to eq("Hello")
      expect(entry.to_s).to include("[info] Hello")
    end

    it "creates a default build logger that filters low-severity entries" do
      output = StringIO.new
      logger = E2B.default_build_logger(min_level: "warn", io: output)

      logger.call(E2B::Models::TemplateLogEntryStart.new(timestamp: Time.now, message: "Build started"))
      logger.call(E2B::Models::TemplateLogEntry.new(timestamp: Time.parse("2026-03-13T09:00:00Z"), level: "info", message: "Skip"))
      logger.call(E2B::Models::TemplateLogEntry.new(timestamp: Time.parse("2026-03-13T09:00:01Z"), level: "warn", message: "Warn"))
      logger.call(E2B::Models::TemplateLogEntryEnd.new(timestamp: Time.now, message: "Build finished"))

      expect(output.string).to include("WARN")
      expect(output.string).to include("Warn")
      expect(output.string).not_to include("Skip")
    end
  end

  describe "template defaults" do
    it "uses the caller file directory as the default file context path" do
      template = described_class.new

      expect(template.send(:file_context_path)).to eq(File.dirname(__FILE__))
    end
  end

  describe "builder serialization" do
    it "serializes image-based templates to hashes and Dockerfiles" do
      template = described_class.new
        .from_python_image("3.12")
        .copy("app.rb", "/app/")
        .run_cmd("bundle install", user: "root")
        .set_workdir("/app")
        .set_user("app")
        .set_envs("RACK_ENV" => "production", "PORT" => 3000)
        .set_start_cmd("bundle exec ruby app.rb", "test -f /tmp/ready")

      expect(template.to_h).to eq(
        fromImage: "python:3.12",
        startCmd: "bundle exec ruby app.rb",
        readyCmd: "test -f /tmp/ready",
        force: false,
        steps: [
          { type: "COPY", args: ["app.rb", "/app/", "", ""], force: false },
          { type: "RUN", args: ["bundle install", "root"], force: false },
          { type: "WORKDIR", args: ["/app"], force: false },
          { type: "USER", args: ["app"], force: false },
          { type: "ENV", args: ["RACK_ENV", "production", "PORT", "3000"], force: false }
        ]
      )

      expect(described_class.to_dockerfile(template)).to eq(<<~DOCKERFILE)
        FROM python:3.12
        COPY app.rb /app/
        RUN bundle install
        WORKDIR /app
        USER app
        ENV RACK_ENV=production PORT=3000
        ENTRYPOINT bundle exec ruby app.rb
      DOCKERFILE
    end

    it "marks subsequent steps as forced after skip_cache" do
      template = described_class.new
        .skip_cache
        .from_base_image
        .run_cmd("echo hi")

      expect(template.to_h).to eq(
        fromImage: "e2bdev/base",
        force: true,
        steps: [
          { type: "RUN", args: ["echo hi", ""], force: true }
        ]
      )
    end

    it "joins array commands into a single RUN step" do
      template = described_class.new
        .from_base_image
        .run_cmd(["apt-get update", "apt-get install -y git"], user: "root")

      expect(template.to_h[:steps]).to eq([
        { type: "RUN", args: ["apt-get update && apt-get install -y git", "root"], force: false }
      ])
    end

    it "computes file hashes for copy steps" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "app.rb"), "puts 'hello'\n")
        template = described_class.new(file_context_path: dir)
          .from_base_image
          .copy("app.rb", "/app/")

        payload = template.to_h(compute_hashes: true)

        expect(payload[:steps].first[:filesHash]).to match(/\A\h{64}\z/)
      end
    end

    it "includes file hashes in JSON output by default" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "app.rb"), "puts 'hello'\n")
        template = described_class.new(file_context_path: dir)
          .from_base_image
          .copy("app.rb", "/app/")

        json = described_class.to_json(template)

        expect(json).to include("\"filesHash\"")
      end
    end

    it "rejects copy sources that escape the template context" do
      template = described_class.new

      expect {
        template.copy("../secrets.txt", "/app/")
      }.to raise_error(E2B::TemplateError, /path escapes the context directory/)
    end

    it "refuses to convert templates based on other templates to Dockerfiles" do
      template = described_class.new.from_template("base-template")

      expect {
        template.to_dockerfile
      }.to raise_error(E2B::TemplateError, /Cannot convert template built from another template to Dockerfile/)
    end

    it "serializes copy_items and filesystem mutation helpers" do
      template = described_class.new
        .from_base_image
        .copy_items([
          { src: "app.rb", dest: "/app/" },
          { "src" => "config.yml", "dest" => "/etc/app/", "mode" => 0o644, "user" => "root" }
        ])
        .remove(["/tmp/cache", "/tmp/build"], recursive: true, force: true, user: "root")
        .rename("/etc/app/config.yml", "/etc/app/settings.yml", force: true)
        .make_dir(["/app/logs", "/app/tmp"], mode: 0o755)
        .make_symlink("/usr/bin/python3", "/usr/bin/python", force: true, user: "root")

      expect(template.to_h[:steps]).to eq([
        { type: "COPY", args: ["app.rb", "/app/", "", ""], force: false },
        { type: "COPY", args: ["config.yml", "/etc/app/", "root", "0644"], force: false },
        { type: "RUN", args: ["rm -r -f /tmp/cache /tmp/build", "root"], force: false },
        { type: "RUN", args: ["mv -f /etc/app/config.yml /etc/app/settings.yml", ""], force: false },
        { type: "RUN", args: ["mkdir -p -m 0755 /app/logs /app/tmp", ""], force: false },
        { type: "RUN", args: ["ln -s -f /usr/bin/python3 /usr/bin/python", "root"], force: false }
      ])
    end

    it "serializes AWS and GCP registry sources" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "gcp.json"), "{\"client_email\":\"svc@example.test\"}")

        aws_template = described_class.new
          .from_aws_registry(
            "123456789.dkr.ecr.us-west-2.amazonaws.com/app:latest",
            access_key_id: "AKIA123",
            secret_access_key: "secret",
            region: "us-west-2"
          )
        gcp_template = described_class.new(file_context_path: dir)
          .from_gcp_registry("gcr.io/project/app:latest", service_account_json: "gcp.json")

        expect(aws_template.to_h).to include(
          fromImage: "123456789.dkr.ecr.us-west-2.amazonaws.com/app:latest",
          fromImageRegistry: {
            type: "aws",
            awsAccessKeyId: "AKIA123",
            awsSecretAccessKey: "secret",
            awsRegion: "us-west-2"
          }
        )
        expect(gcp_template.to_h).to include(
          fromImage: "gcr.io/project/app:latest",
          fromImageRegistry: {
            type: "gcp",
            serviceAccountJson: "{\"client_email\":\"svc@example.test\"}"
          }
        )
      end
    end

    it "serializes package installers, git clone, and leaves empty env hashes as no-ops" do
      template = described_class.new
        .from_base_image
        .set_envs({})
        .pip_install(["numpy", "pandas"], g: false)
        .npm_install("typescript", g: true)
        .bun_install("tsx", dev: true)
        .apt_install(%w[git curl], no_install_recommends: true)
        .git_clone("https://github.com/e2b-dev/E2B.git", "/app/repo", branch: "main", depth: 1, user: "root")

      expect(template.to_h[:steps]).to eq([
        { type: "RUN", args: ["pip install --user numpy pandas", ""], force: false },
        { type: "RUN", args: ["npm install -g typescript", "root"], force: false },
        { type: "RUN", args: ["bun install --dev tsx", ""], force: false },
        {
          type: "RUN",
          args: [
            "apt-get update && DEBIAN_FRONTEND=noninteractive DEBCONF_NOWARNINGS=yes apt-get install -y --no-install-recommends git curl",
            "root"
          ],
          force: false
        },
        {
          type: "RUN",
          args: [
            "git clone https://github.com/e2b-dev/E2B.git --branch main --single-branch --depth 1 /app/repo",
            "root"
          ],
          force: false
        }
      ])
    end

    it "guards MCP server helpers to the mcp-gateway template" do
      template = described_class.new.from_base_image

      expect {
        template.add_mcp_server("exa")
      }.to raise_error(E2B::BuildError, /MCP servers can only be added to mcp-gateway template/)
    end

    it "serializes MCP and devcontainer helpers on the matching templates" do
      mcp_template = described_class.new
        .from_template("mcp-gateway")
        .add_mcp_server(%w[exa brave])
      devcontainer_template = described_class.new
        .from_template("devcontainer")
        .beta_dev_container_prebuild("/workspace/project")
        .beta_set_devcontainer_start("/workspace/project")

      expect(mcp_template.to_h).to include(
        fromTemplate: "mcp-gateway",
        steps: [
          { type: "RUN", args: ["mcp-gateway pull exa brave", "root"], force: false }
        ]
      )
      expect(devcontainer_template.to_h).to include(
        fromTemplate: "devcontainer",
        readyCmd: "[ -f /devcontainer.up ]",
        startCmd: "sudo devcontainer up --workspace-folder /workspace/project && sudo /prepare-exec.sh /workspace/project | sudo tee /devcontainer.sh > /dev/null && sudo chmod +x /devcontainer.sh && sudo touch /devcontainer.up"
      )
      expect(devcontainer_template.to_h[:steps]).to eq([
        { type: "RUN", args: ["devcontainer build --workspace-folder /workspace/project", "root"], force: false }
      ])
    end
  end

  describe ".build_in_background" do
    it "requests, uploads, and triggers template builds" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "app.rb"), "puts 'hello'\n")
        template = described_class.new(file_context_path: dir)
          .from_base_image
          .copy("app.rb", "/app/")

        payload = template.to_h(compute_hashes: true)
        files_hash = payload[:steps].first[:filesHash]
        logs = []

        allow(http_client).to receive(:post)
          .with(
            "/v3/templates",
            body: {
              name: "my-template",
              tags: ["stable"],
              cpuCount: 2,
              memoryMB: 1024
            }
          )
          .and_return({
            "templateID" => "tpl_123",
            "buildID" => "bld_123",
            "tags" => ["stable"]
          })
        allow(http_client).to receive(:get)
          .with("/templates/tpl_123/files/#{files_hash}")
          .and_return({
            "present" => false,
            "url" => "https://upload.example.test/template"
          })
        allow(described_class).to receive(:upload_file)
        expect(http_client).to receive(:post)
          .with("/v2/templates/tpl_123/builds/bld_123", body: payload)

        build_info = described_class.build_in_background(
          template,
          name: "my-template",
          tags: ["stable"],
          api_key: "api-key",
          on_build_logs: ->(entry) { logs << entry.message }
        )

        expect(build_info).to be_a(E2B::Models::BuildInfo)
        expect(build_info.template_id).to eq("tpl_123")
        expect(build_info.build_id).to eq("bld_123")
        expect(described_class).to have_received(:upload_file).with(
          template,
          file_name: "app.rb",
          url: "https://upload.example.test/template",
          resolve_symlinks: true
        )
        expect(logs).to include(
          "Requesting build for template: my-template with tags stable",
          "Template created with ID: tpl_123, Build ID: bld_123",
          "Uploaded 'app.rb'",
          "All file uploads completed",
          "Starting building..."
        )
      end
    end

    it "parses Dockerfile content into builder instructions" do
      dockerfile = <<~DOCKERFILE
        FROM python:3.12
        ARG APP_ENV
        ENV PORT=3000 APP_ENV=production
        COPY --chown=root:root app.py /app/app.py
        RUN pip install -r requirements.txt \\
          && python -m compileall /app
        CMD ["python", "/app/app.py"]
      DOCKERFILE

      template = described_class.new.from_dockerfile(dockerfile)

      expect(template.to_h).to eq(
        fromImage: "python:3.12",
        startCmd: "python /app/app.py",
        readyCmd: "sleep 20",
        force: false,
        steps: [
          { type: "USER", args: ["root"], force: false },
          { type: "WORKDIR", args: ["/"], force: false },
          { type: "ENV", args: ["APP_ENV", ""], force: false },
          { type: "ENV", args: ["PORT", "3000", "APP_ENV", "production"], force: false },
          { type: "COPY", args: ["app.py", "/app/app.py", "root:root", ""], force: false },
          { type: "RUN", args: ["pip install -r requirements.txt && python -m compileall /app", ""], force: false },
          { type: "USER", args: ["user"], force: false },
          { type: "WORKDIR", args: ["/home/user"], force: false }
        ]
      )
    end

    it "parses Dockerfile files from disk and preserves explicit user/workdir instructions" do
      Dir.mktmpdir do |dir|
        dockerfile_path = File.join(dir, "Dockerfile")
        File.write(dockerfile_path, <<~DOCKERFILE)
          FROM ruby:3.3
          WORKDIR /app
          USER app
          ENTRYPOINT bundle exec ruby server.rb
        DOCKERFILE

        template = described_class.new.from_dockerfile(dockerfile_path)

        expect(template.to_h).to eq(
          fromImage: "ruby:3.3",
          startCmd: "bundle exec ruby server.rb",
          readyCmd: "sleep 20",
          force: false,
          steps: [
            { type: "USER", args: ["root"], force: false },
            { type: "WORKDIR", args: ["/"], force: false },
            { type: "WORKDIR", args: ["/app"], force: false },
            { type: "USER", args: ["app"], force: false }
          ]
        )
      end
    end

    it "rejects multi-stage Dockerfiles" do
      dockerfile = <<~DOCKERFILE
        FROM node:20 AS builder
        RUN npm install
        FROM nginx:stable
      DOCKERFILE

      expect {
        described_class.new.from_dockerfile(dockerfile)
      }.to raise_error(E2B::TemplateError, /Multi-stage Dockerfiles are not supported/)
    end
  end

  describe ".build" do
    it "waits for the build to finish after triggering it in the background" do
      build_info = E2B::Models::BuildInfo.new(
        alias_name: "my-template",
        name: "my-template",
        tags: ["stable"],
        template_id: "tpl_123",
        build_id: "bld_123"
      )
      allow(described_class).to receive(:build_in_background).and_return(build_info)
      allow(described_class).to receive(:wait_for_build_finish)

      logs = []
      result = described_class.build(
        described_class.new.from_base_image,
        name: "my-template",
        api_key: "api-key",
        on_build_logs: ->(entry) { logs << entry.message }
      )

      expect(result).to eq(build_info)
      expect(described_class).to have_received(:wait_for_build_finish).with(
        build_info,
        on_build_logs: kind_of(Proc),
        api_key: "api-key",
        access_token: nil,
        domain: nil
      )
      expect(logs.first).to eq("Build started")
      expect(logs).to include("Waiting for logs...")
      expect(logs.last).to eq("Build finished")
    end

    it "accepts the deprecated alias option for build parity" do
      build_info = E2B::Models::BuildInfo.new(
        alias_name: "my-template",
        name: "my-template",
        tags: [],
        template_id: "tpl_123",
        build_id: "bld_123"
      )
      allow(described_class).to receive(:build_in_background).and_return(build_info)
      allow(described_class).to receive(:wait_for_build_finish)

      result = described_class.build(
        described_class.new.from_base_image,
        **{ alias: "my-template", api_key: "api-key" }
      )

      expect(result).to eq(build_info)
      expect(described_class).to have_received(:build_in_background).with(
        kind_of(E2B::Template),
        name: nil,
        alias_name: "my-template",
        tags: nil,
        cpu_count: 2,
        memory_mb: 1024,
        skip_cache: false,
        on_build_logs: nil,
        api_key: "api-key",
        access_token: nil,
        domain: nil
      )
    end
  end
end
