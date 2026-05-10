# frozen_string_literal: true

require "spec_helper"

RSpec.describe E2B::Services::Git do
  subject(:git) { described_class.new(commands: commands) }

  let(:commands) { instance_double(E2B::Services::Commands) }

  def process_result(stdout: "", stderr: "", exit_code: 0)
    E2B::Models::ProcessResult.new(
      stdout: stdout,
      stderr: stderr,
      exit_code: exit_code
    )
  end

  describe "credential URL helpers (private)" do
    it "embeds and strips credentials on a vanilla HTTPS URL" do
      embedded = git.send(:with_credentials, "https://github.com/owner/repo.git", "alice", "s3cret")
      expect(embedded).to eq("https://alice:s3cret@github.com/owner/repo.git")

      stripped = git.send(:strip_credentials, embedded)
      expect(stripped).to eq("https://github.com/owner/repo.git")
    end

    it "URL-encodes special characters in the username and password" do
      embedded = git.send(:with_credentials,
                          "https://example.com/r.git",
                          "user@example.com",
                          "p@ss:w/rd")

      # `@` -> %40, `:` -> %3A, `/` -> %2F. These must be encoded — otherwise
      # the URI parser would mis-attribute the password's `@` as the userinfo
      # boundary and the leak the rest of the password into the hostname slot.
      expect(embedded).to include("user%40example.com:p%40ss%3Aw%2Frd@example.com")
    end

    it "returns the original string when URI cannot parse it (e.g. SSH form)" do
      ssh_url = "git@github.com:owner/repo.git"
      expect(git.send(:with_credentials, ssh_url, "alice", "x")).to eq(ssh_url)
      expect(git.send(:strip_credentials, ssh_url)).to eq(ssh_url)
    end

    it "strips credentials that were already present in the URL" do
      stripped = git.send(:strip_credentials, "https://carol:tok@example.com/r.git")
      expect(stripped).to eq("https://example.com/r.git")
    end
  end

  describe "#clone" do
    it "passes the URL through verbatim when no credentials are given" do
      expected_cmd = "git clone #{Shellwords.escape("https://github.com/o/r.git")}"
      expect(commands).to receive(:run)
        .with(expected_cmd, hash_including(envs: hash_including("GIT_TERMINAL_PROMPT" => "0")))
        .and_return(process_result)

      git.clone("https://github.com/o/r.git")
    end

    it "embeds credentials into the URL before running the clone" do
      authed = "https://alice:tok@github.com/o/r.git"
      expect(commands).to receive(:run)
        .with("git clone #{Shellwords.escape(authed)}",
              hash_including(envs: hash_including("GIT_TERMINAL_PROMPT" => "0")))
        .and_return(process_result)

      git.clone("https://github.com/o/r.git", username: "alice", password: "tok")
    end

    it "raises GitAuthError when stderr indicates an auth failure" do
      allow(commands).to receive(:run).and_return(
        process_result(exit_code: 128, stderr: "fatal: Authentication failed for 'https://...'")
      )

      expect { git.clone("https://github.com/o/r.git") }
        .to raise_error(E2B::GitAuthError, /Authentication failed/)
    end
  end

  describe "#status" do
    it "parses branch info, ahead/behind counts, modified, and untracked entries" do
      raw = <<~PORCELAIN
        # branch.head main
        # branch.upstream origin/main
        # branch.ab +2 -1
        1 .M N... 100644 100644 100644 deadbeef deadbeef README.md
        ? scratch.log
      PORCELAIN

      allow(commands).to receive(:run).and_return(process_result(stdout: raw))

      status = git.status("/repo")

      expect(status.current_branch).to eq("main")
      expect(status.upstream).to eq("origin/main")
      expect(status.ahead).to eq(2)
      expect(status.behind).to eq(1)
      expect(status.detached).to be(false)
      expect(status.modified_count).to eq(1)
      expect(status.untracked_count).to eq(1)
      expect(status).not_to be_clean
    end

    it "marks HEAD as detached without setting current_branch" do
      raw = "# branch.head (detached)\n"
      allow(commands).to receive(:run).and_return(process_result(stdout: raw))

      status = git.status("/repo")

      expect(status.detached).to be(true)
      expect(status.current_branch).to be_nil
      expect(status).to be_clean
    end
  end

  describe "#branches" do
    # The parser routes any ref containing `/` to `remote`. That matches
    # real `git branch -a --format=%(refname:short)` output (locals are
    # bare names; remotes are `origin/...`) but means a local branch
    # literally named `feature/x` would be mis-routed. Use `dev` here.
    it "splits local and remote, marks current via the trailing `*`, and drops origin/HEAD" do
      raw = <<~LIST
        main *
        dev
        origin/main
        origin/HEAD
      LIST

      allow(commands).to receive(:run).and_return(process_result(stdout: raw))

      branches = git.branches("/repo")

      expect(branches.current).to eq("main")
      expect(branches.local).to contain_exactly("main", "dev")
      expect(branches.remote).to contain_exactly("origin/main")
    end
  end

  describe "#push" do
    it "raises GitUpstreamError when stderr indicates a missing upstream branch" do
      allow(commands).to receive(:run).and_return(
        process_result(exit_code: 128, stderr: "fatal: The current branch foo has no upstream branch.")
      )

      expect { git.push("/repo", remote: "origin", branch: "foo", set_upstream: false) }
        .to raise_error(E2B::GitUpstreamError, /upstream/)
    end
  end

  describe "default git environment" do
    it "always sets GIT_TERMINAL_PROMPT=0 to prevent envd hangs on credential prompts" do
      received_envs = nil
      allow(commands).to receive(:run) do |_cmd, envs:, **|
        received_envs = envs
        process_result
      end

      git.init("/repo")

      expect(received_envs["GIT_TERMINAL_PROMPT"]).to eq("0")
    end
  end
end
