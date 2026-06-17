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

  # Records every command string handed to commands.run, in order, so that
  # multi-step flows (push/pull with credentials) can be asserted as a sequence.
  # Queued +results+ are returned one per call; once exhausted, a success result
  # is returned so cleanup steps still observe a healthy exit.
  def stub_run_sequence(*results)
    calls = []
    allow(commands).to receive(:run) do |cmd, **kwargs|
      calls << { cmd: cmd, kwargs: kwargs }
      results.empty? ? process_result : (results.shift || process_result)
    end
    calls
  end

  # Capture just the command string produced by a single delegated call.
  def captured_cmd
    received = nil
    allow(commands).to receive(:run) do |cmd, **|
      received = cmd
      process_result
    end
    yield
    received
  end

  describe "#init" do
    it "builds a plain init command with the path appended" do
      expect(captured_cmd { git.init("/repo") }).to eq("git init #{Shellwords.escape("/repo")}")
    end

    it "passes --bare and --initial-branch when requested" do
      cmd = captured_cmd { git.init("/repo", bare: true, initial_branch: "main") }
      expect(cmd).to eq("git init --bare --initial-branch main #{Shellwords.escape("/repo")}")
    end
  end

  describe "#remote_add" do
    it "adds the remote under the repo path by default" do
      cmd = captured_cmd { git.remote_add("/repo", "origin", "https://github.com/o/r.git") }
      expect(cmd).to eq("git -C #{Shellwords.escape("/repo")} remote add origin " \
                        "#{Shellwords.escape("https://github.com/o/r.git")}")
    end

    it "fetches after adding when fetch: true" do
      calls = stub_run_sequence
      git.remote_add("/repo", "origin", "https://github.com/o/r.git", fetch: true)

      cmds = calls.map { |c| c[:cmd] }
      expect(cmds.last).to eq("git -C #{Shellwords.escape("/repo")} fetch origin")
    end

    it "set-urls an existing remote when overwrite: true and the remote exists" do
      # First call is remote_get returning a URL → remote exists → set-url.
      calls = stub_run_sequence(process_result(stdout: "https://old.example/r.git\n"))
      git.remote_add("/repo", "origin", "https://new.example/r.git", overwrite: true)

      cmds = calls.map { |c| c[:cmd] }
      expect(cmds[0]).to eq("git -C #{Shellwords.escape("/repo")} remote get-url origin")
      expect(cmds[1]).to eq("git -C #{Shellwords.escape("/repo")} remote set-url origin " \
                            "#{Shellwords.escape("https://new.example/r.git")}")
    end

    it "adds a new remote when overwrite: true but the remote does not exist" do
      # remote_get returns a failure → nil → fall back to `remote add`.
      calls = stub_run_sequence(process_result(exit_code: 2))
      git.remote_add("/repo", "origin", "https://new.example/r.git", overwrite: true)

      cmds = calls.map { |c| c[:cmd] }
      expect(cmds[1]).to eq("git -C #{Shellwords.escape("/repo")} remote add origin " \
                            "#{Shellwords.escape("https://new.example/r.git")}")
    end
  end

  describe "#remote_get" do
    it "returns the trimmed remote URL on success" do
      allow(commands).to receive(:run).and_return(process_result(stdout: "https://github.com/o/r.git\n"))
      expect(git.remote_get("/repo", "origin")).to eq("https://github.com/o/r.git")
    end

    it "returns nil when the command fails" do
      allow(commands).to receive(:run).and_return(process_result(exit_code: 2, stderr: "No such remote"))
      expect(git.remote_get("/repo", "origin")).to be_nil
    end

    it "returns nil when the URL is blank" do
      allow(commands).to receive(:run).and_return(process_result(stdout: "  \n"))
      expect(git.remote_get("/repo", "origin")).to be_nil
    end
  end

  describe "branch operations" do
    it "creates, checks out, and deletes branches" do
      expect(captured_cmd { git.create_branch("/repo", "feature") })
        .to eq("git -C #{Shellwords.escape("/repo")} branch feature")
      expect(captured_cmd { git.checkout_branch("/repo", "feature") })
        .to eq("git -C #{Shellwords.escape("/repo")} checkout feature")
      expect(captured_cmd { git.delete_branch("/repo", "feature") })
        .to eq("git -C #{Shellwords.escape("/repo")} branch -d feature")
    end

    it "force-deletes with -D when force: true" do
      expect(captured_cmd { git.delete_branch("/repo", "feature", force: true) })
        .to eq("git -C #{Shellwords.escape("/repo")} branch -D feature")
    end
  end

  describe "#add" do
    it "stages everything with -A by default" do
      expect(captured_cmd { git.add("/repo") })
        .to eq("git -C #{Shellwords.escape("/repo")} add -A")
    end

    it "stages specific escaped files when all: false" do
      cmd = captured_cmd { git.add("/repo", all: false, files: ["a.rb", "spaced name.rb"]) }
      expect(cmd).to eq("git -C #{Shellwords.escape("/repo")} add " \
                        "#{Shellwords.escape("a.rb")} #{Shellwords.escape("spaced name.rb")}")
    end

    it "falls back to -A when all: false but no files are given" do
      expect(captured_cmd { git.add("/repo", all: false, files: []) })
        .to eq("git -C #{Shellwords.escape("/repo")} add -A")
    end
  end

  describe "#commit" do
    it "escapes the message and can allow empty commits" do
      cmd = captured_cmd { git.commit("/repo", "initial commit", allow_empty: true) }
      expect(cmd).to eq("git -C #{Shellwords.escape("/repo")} commit -m " \
                        "#{Shellwords.escape("initial commit")} --allow-empty")
    end

    it "sets author and committer env vars when both name and email are given" do
      received_envs = nil
      allow(commands).to receive(:run) do |_cmd, envs:, **|
        received_envs = envs
        process_result
      end

      git.commit("/repo", "msg", author_name: "Bot", author_email: "bot@example.com")

      expect(received_envs).to include(
        "GIT_AUTHOR_NAME" => "Bot",
        "GIT_COMMITTER_NAME" => "Bot",
        "GIT_AUTHOR_EMAIL" => "bot@example.com",
        "GIT_COMMITTER_EMAIL" => "bot@example.com"
      )
    end

    it "does not set author env vars when only one of name/email is given" do
      received_envs = nil
      allow(commands).to receive(:run) do |_cmd, envs:, **|
        received_envs = envs
        process_result
      end

      git.commit("/repo", "msg", author_name: "Bot")

      expect(received_envs).not_to have_key("GIT_AUTHOR_NAME")
    end
  end

  describe "#reset" do
    it "builds reset with a mode and target" do
      expect(captured_cmd { git.reset("/repo", mode: "hard", target: "HEAD~1") })
        .to eq("git -C #{Shellwords.escape("/repo")} reset --hard HEAD~1")
    end

    it "appends a -- separator and escaped paths when unstaging specific files" do
      cmd = captured_cmd { git.reset("/repo", paths: ["a.rb", "b c.rb"]) }
      expect(cmd).to eq("git -C #{Shellwords.escape("/repo")} reset -- " \
                        "#{Shellwords.escape("a.rb")} #{Shellwords.escape("b c.rb")}")
    end
  end

  describe "#restore" do
    it "restores an array of paths with --staged and --worktree flags" do
      cmd = captured_cmd { git.restore("/repo", ["a.rb", "b.rb"], staged: true, worktree: true) }
      expect(cmd).to eq("git -C #{Shellwords.escape("/repo")} restore --staged --worktree " \
                        "#{Shellwords.escape("a.rb")} #{Shellwords.escape("b.rb")}")
    end

    it "restores a single path string from a given source" do
      cmd = captured_cmd { git.restore("/repo", "a.rb", source: "HEAD") }
      expect(cmd).to eq("git -C #{Shellwords.escape("/repo")} restore --source HEAD " \
                        "#{Shellwords.escape("a.rb")}")
    end
  end

  describe "#push with credentials" do
    it "temporarily authenticates the remote URL and restores it afterwards" do
      calls = stub_run_sequence(
        process_result(stdout: "https://github.com/o/r.git\n") # remote_get
      )

      git.push("/repo", remote: "origin", branch: "main",
                        username: "alice", password: "tok")

      cmds = calls.map { |c| c[:cmd] }
      expect(cmds[0]).to eq("git -C #{Shellwords.escape("/repo")} remote get-url origin")
      expect(cmds[1]).to eq("git -C #{Shellwords.escape("/repo")} remote set-url origin " \
                            "#{Shellwords.escape("https://alice:tok@github.com/o/r.git")}")
      expect(cmds[2]).to eq("git -C #{Shellwords.escape("/repo")} push -u origin main")
      # Cleanup must strip the credentials back out of the stored URL.
      expect(cmds[3]).to eq("git -C #{Shellwords.escape("/repo")} remote set-url origin " \
                            "#{Shellwords.escape("https://github.com/o/r.git")}")
    end

    it "restores the original URL even when the push itself fails" do
      calls = stub_run_sequence(
        process_result(stdout: "https://github.com/o/r.git\n"), # remote_get
        process_result, # set-url authed
        process_result(exit_code: 128, stderr: "fatal: Authentication failed") # push
      )

      expect do
        git.push("/repo", username: "alice", password: "tok")
      end.to raise_error(E2B::GitAuthError)

      # The ensure block still ran the credential-stripping set-url.
      expect(calls.last[:cmd]).to eq("git -C #{Shellwords.escape("/repo")} remote set-url origin " \
                                     "#{Shellwords.escape("https://github.com/o/r.git")}")
    end

    it "raises E2BError when the remote to authenticate does not exist" do
      stub_run_sequence(process_result(exit_code: 2)) # remote_get fails → nil

      expect do
        git.push("/repo", username: "alice", password: "tok")
      end.to raise_error(E2B::E2BError, /Remote 'origin' not found/)
    end
  end

  describe "#pull" do
    it "pulls from the default origin remote" do
      expect(captured_cmd { git.pull("/repo", branch: "main") })
        .to eq("git -C #{Shellwords.escape("/repo")} pull origin main")
    end

    it "raises GitAuthError when authentication fails" do
      allow(commands).to receive(:run).and_return(
        process_result(exit_code: 128, stderr: "fatal: could not read Username")
      )

      expect { git.pull("/repo") }.to raise_error(E2B::GitAuthError)
    end
  end

  describe "git config" do
    it "rejects an invalid scope" do
      expect { git.set_config("user.name", "Alice", scope: "bogus") }
        .to raise_error(E2B::E2BError, /Invalid git config scope/)
    end

    it "writes a scoped, escaped config value" do
      expect(captured_cmd { git.set_config("user.name", "Alice Smith", scope: "global") })
        .to eq("git config --global user.name #{Shellwords.escape("Alice Smith")}")
    end

    it "reads a config value, returning nil when unset" do
      allow(commands).to receive(:run).and_return(process_result(stdout: "Alice\n"))
      expect(git.get_config("user.name")).to eq("Alice")

      allow(commands).to receive(:run).and_return(process_result(exit_code: 1))
      expect(git.get_config("user.name")).to be_nil
    end

    it "configure_user sets both user.name and user.email" do
      calls = stub_run_sequence
      git.configure_user("Alice", "alice@example.com", scope: "local", path: "/repo")

      cmds = calls.map { |c| c[:cmd] }
      expect(cmds).to contain_exactly(
        "git -C #{Shellwords.escape("/repo")} config --local user.name #{Shellwords.escape("Alice")}",
        "git -C #{Shellwords.escape("/repo")} config --local user.email #{Shellwords.escape("alice@example.com")}"
      )
    end
  end

  describe "#dangerously_authenticate" do
    it "enables the store helper and pipes credentials into git credential approve" do
      calls = stub_run_sequence
      git.dangerously_authenticate("alice", "tok", host: "github.com")

      cmds = calls.map { |c| c[:cmd] }
      expect(cmds[0]).to eq("git config --global credential.helper #{Shellwords.escape("store")}")
      # The credential block is shell-escaped as a single echo argument, so the
      # raw `username=alice` becomes `username\=alice` once Shellwords escapes `=`.
      expect(cmds[1]).to start_with("echo ")
      expect(cmds[1]).to include("| git credential approve")
      expect(cmds[1]).to include("alice")
      expect(cmds[1]).to include("tok")
      expect(cmds[1]).to include("host\\=github.com")
    end
  end

  describe "#status parsing of rename and unmerged entries" do
    it "uses the new path for renames and flags staged/conflicted/clean states" do
      raw = <<~PORCELAIN
        # branch.head main
        2 R. N... 100644 100644 100644 deadbeef deadbeef R100 new_name.rb\told_name.rb
        u UU N... 100644 100644 100644 100644 aaa bbb ccc conflicted.rb
        1 M. N... 100644 100644 100644 deadbeef deadbeef staged.rb
      PORCELAIN

      allow(commands).to receive(:run).and_return(process_result(stdout: raw))
      status = git.status("/repo")

      paths = status.file_status.map(&:path)
      expect(paths).to include("new_name.rb", "conflicted.rb", "staged.rb")
      expect(paths).not_to include("new_name.rb\told_name.rb")

      expect(status.has_staged?).to be(true)
      expect(status.has_conflicts?).to be(true)
      expect(status.conflict_count).to eq(1)
      # staged_count counts any entry whose index status is neither "." nor "?",
      # which includes the unmerged ("u") entry — so rename + unmerged + modified.
      expect(status.staged_count).to eq(3)
    end
  end

  describe E2B::Services::GitStatus do
    def fs(index, work, path = "f")
      E2B::Services::GitFileStatus.new(path: path, index_status: index, work_tree_status: work)
    end

    it "reports a clean tree when there are no entries" do
      status = described_class.new
      expect(status).to be_clean
      expect(status.has_changes?).to be(false)
    end

    it "counts staged, untracked, conflicted, and modified entries independently" do
      status = described_class.new(file_status: [
                                     fs("M", ".", "staged.rb"),     # staged
                                     fs("?", "?", "untracked.rb"),  # untracked
                                     fs("u", "U", "conflict.rb"),   # conflict
                                     fs(".", "M", "dirty.rb")       # modified worktree only
                                   ])

      expect(status).to have_changes
      expect(status.has_staged?).to be(true)
      # Both the "M" and the conflicted "u" index statuses count as staged.
      expect(status.staged_count).to eq(2)
      expect(status.has_untracked?).to be(true)
      expect(status.untracked_count).to eq(1)
      expect(status.has_conflicts?).to be(true)
      expect(status.conflict_count).to eq(1)
      expect(status.modified_count).to eq(1)
    end
  end
end
