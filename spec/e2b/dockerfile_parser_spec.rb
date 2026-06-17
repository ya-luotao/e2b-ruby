# frozen_string_literal: true

require "spec_helper"
require "tempfile"

# Minimal stand-in for the Template builder. Records every call the parser makes
# (via method_missing, so it mirrors the builder's setter-style interface
# without re-declaring those method names) instead of building a real template.
class RecordingBuilder
  attr_reader :calls

  def initialize
    @calls = []
  end

  def calls_of(name)
    @calls.select { |c| c.first == name }
  end

  def respond_to_missing?(_name, _include_private = false) = true

  def method_missing(name, *args, **kwargs)
    entry = [name, *args]
    entry << kwargs unless kwargs.empty?
    @calls << entry
    nil
  end
end

RSpec.describe E2B::DockerfileParser do
  # Records every builder call so specs can assert on the translated template.
  let(:builder) { RecordingBuilder.new }

  describe ".parse base image handling" do
    it "returns the base image from a single FROM instruction" do
      expect(described_class.parse("FROM ubuntu:22.04", builder)).to eq("ubuntu:22.04")
    end

    it "strips an `AS stage` alias from the base image" do
      expect(described_class.parse("FROM ubuntu:22.04 AS build", builder)).to eq("ubuntu:22.04")
    end

    it "raises when there is no FROM instruction" do
      expect { described_class.parse("RUN echo hi", builder) }
        .to raise_error(E2B::TemplateError, /must contain a FROM instruction/)
    end

    it "raises on multi-stage Dockerfiles" do
      dockerfile = <<~DOCKER
        FROM ubuntu:22.04 AS build
        RUN make
        FROM ubuntu:22.04
        COPY --from=build /app /app
      DOCKER

      expect { described_class.parse(dockerfile, builder) }
        .to raise_error(E2B::TemplateError, /Multi-stage Dockerfiles are not supported/)
    end
  end

  describe ".parse user/workdir defaults" do
    it "defaults user to 'user' and workdir to '/home/user' when not overridden" do
      described_class.parse("FROM ubuntu", builder)

      # Parser primes root/'/' first, then applies defaults at the end.
      expect(builder.calls_of(:set_user)).to eq([[:set_user, "root"], [:set_user, "user"]])
      expect(builder.calls_of(:set_workdir)).to eq([[:set_workdir, "/"], [:set_workdir, "/home/user"]])
    end

    it "does not re-apply defaults when USER and WORKDIR are present" do
      dockerfile = <<~DOCKER
        FROM ubuntu
        USER app
        WORKDIR /srv
      DOCKER

      described_class.parse(dockerfile, builder)

      expect(builder.calls_of(:set_user)).to eq([[:set_user, "root"], [:set_user, "app"]])
      expect(builder.calls_of(:set_workdir)).to eq([[:set_workdir, "/"], [:set_workdir, "/srv"]])
    end
  end

  describe ".parse RUN handling" do
    it "collapses internal whitespace and joins line continuations" do
      dockerfile = <<~DOCKER
        FROM ubuntu
        RUN apt-get update && \\
            apt-get install -y curl
      DOCKER

      described_class.parse(dockerfile, builder)

      expect(builder.calls_of(:run_cmd)).to eq([[:run_cmd, "apt-get update && apt-get install -y curl"]])
    end

    it "ignores comment and blank lines" do
      dockerfile = <<~DOCKER
        FROM ubuntu
        # a comment
        RUN echo hi

      DOCKER

      described_class.parse(dockerfile, builder)

      expect(builder.calls_of(:run_cmd)).to eq([[:run_cmd, "echo hi"]])
    end
  end

  describe ".parse COPY/ADD handling" do
    it "extracts src, dest and a --chown owner" do
      described_class.parse("FROM ubuntu\nCOPY --chown=app:app ./src /app", builder)

      expect(builder.calls_of(:copy)).to eq([[:copy, "./src", "/app", { user: "app:app" }]])
    end

    it "treats ADD the same as COPY and leaves user nil without --chown" do
      described_class.parse("FROM ubuntu\nADD file.txt /dest/file.txt", builder)

      expect(builder.calls_of(:copy)).to eq([[:copy, "file.txt", "/dest/file.txt", { user: nil }]])
    end

    it "skips COPY instructions without at least a src and dest" do
      described_class.parse("FROM ubuntu\nCOPY onlyone", builder)

      expect(builder.calls_of(:copy)).to be_empty
    end
  end

  describe ".parse ENV/ARG handling" do
    it "parses `ENV KEY value` (space form)" do
      described_class.parse("FROM ubuntu\nENV FOO bar", builder)

      expect(builder.calls_of(:set_envs)).to eq([[:set_envs, { "FOO" => "bar" }]])
    end

    it "parses multiple `KEY=value` pairs on one line" do
      described_class.parse("FROM ubuntu\nENV A=1 B=2", builder)

      expect(builder.calls_of(:set_envs)).to eq([[:set_envs, { "A" => "1", "B" => "2" }]])
    end

    it "treats a bare ARG name as an empty-valued env" do
      described_class.parse("FROM ubuntu\nARG VERSION", builder)

      expect(builder.calls_of(:set_envs)).to eq([[:set_envs, { "VERSION" => "" }]])
    end

    it "does not emit envs for a bare ENV name" do
      described_class.parse("FROM ubuntu\nENV LONELY", builder)

      expect(builder.calls_of(:set_envs)).to be_empty
    end
  end

  describe ".parse CMD/ENTRYPOINT handling" do
    it "joins a JSON exec-form array into a single command" do
      described_class.parse(%(FROM ubuntu\nCMD ["nginx", "-g", "daemon off;"]), builder)

      start_cmds = builder.calls_of(:set_start_cmd)
      expect(start_cmds.length).to eq(1)
      expect(start_cmds.first[1]).to eq("nginx -g daemon off;")
    end

    it "passes a shell-form command through verbatim" do
      described_class.parse("FROM ubuntu\nENTRYPOINT /usr/bin/start.sh", builder)

      expect(builder.calls_of(:set_start_cmd).first[1]).to eq("/usr/bin/start.sh")
    end
  end

  describe ".read_dockerfile" do
    it "reads contents when given a real file path" do
      Tempfile.create(["Dockerfile", ""]) do |f|
        f.write("FROM alpine")
        f.flush
        expect(described_class.read_dockerfile(f.path)).to eq("FROM alpine")
      end
    end

    it "returns the input unchanged when it is inline content, not a path" do
      expect(described_class.read_dockerfile("FROM alpine\nRUN echo hi"))
        .to eq("FROM alpine\nRUN echo hi")
    end
  end
end
