# frozen_string_literal: true

require "spec_helper"
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
      expect(logs).to include("Waiting for logs...")
    end
  end
end
