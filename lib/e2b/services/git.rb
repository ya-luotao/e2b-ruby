# frozen_string_literal: true

require "uri"
require "shellwords"

module E2B
  module Services
    # Represents the status of a single file in the git working tree
    #
    # @attr_reader path [String] File path relative to the repository root
    # @attr_reader index_status [String] Status in the index (staged area)
    # @attr_reader work_tree_status [String] Status in the working tree
    GitFileStatus = Struct.new(:path, :index_status, :work_tree_status, keyword_init: true)

    # Represents the result of `git status`, including branch info and file statuses
    #
    # @example
    #   status = sandbox.git.status("/home/user/repo")
    #   puts status.current_branch
    #   puts "Clean!" if status.clean?
    class GitStatus
      # @return [String, nil] Name of the current branch, or nil if detached
      attr_reader :current_branch

      # @return [String, nil] Name of the upstream tracking branch
      attr_reader :upstream

      # @return [Integer] Number of commits ahead of upstream
      attr_reader :ahead

      # @return [Integer] Number of commits behind upstream
      attr_reader :behind

      # @return [Boolean] Whether HEAD is in detached state
      attr_reader :detached

      # @return [Array<GitFileStatus>] List of file statuses
      attr_reader :file_status

      # @param current_branch [String, nil] Current branch name
      # @param upstream [String, nil] Upstream tracking branch
      # @param ahead [Integer] Commits ahead of upstream
      # @param behind [Integer] Commits behind upstream
      # @param detached [Boolean] Whether HEAD is detached
      # @param file_status [Array<GitFileStatus>] File status entries
      def initialize(current_branch: nil, upstream: nil, ahead: 0, behind: 0, detached: false, file_status: [])
        @current_branch = current_branch
        @upstream = upstream
        @ahead = ahead
        @behind = behind
        @detached = detached
        @file_status = file_status
      end

      # Whether the working tree is clean (no changes at all)
      #
      # @return [Boolean]
      def clean?
        file_status.empty?
      end

      # Whether the working tree has any changes
      #
      # @return [Boolean]
      def has_changes?
        !clean?
      end

      # Whether there are any staged changes
      #
      # @return [Boolean]
      def has_staged?
        file_status.any? { |f| f.index_status != "." && f.index_status != "?" }
      end

      # Whether there are any untracked files
      #
      # @return [Boolean]
      def has_untracked?
        file_status.any? { |f| f.index_status == "?" }
      end

      # Whether there are any merge conflicts
      #
      # @return [Boolean]
      def has_conflicts?
        file_status.any? { |f| f.index_status == "u" || f.index_status == "U" }
      end

      # Number of staged files
      #
      # @return [Integer]
      def staged_count
        file_status.count { |f| f.index_status != "." && f.index_status != "?" }
      end

      # Number of untracked files
      #
      # @return [Integer]
      def untracked_count
        file_status.count { |f| f.index_status == "?" }
      end

      # Number of conflicted files
      #
      # @return [Integer]
      def conflict_count
        file_status.count { |f| f.index_status == "u" || f.index_status == "U" }
      end

      # Number of modified files (in the working tree)
      #
      # @return [Integer]
      def modified_count
        file_status.count { |f| f.work_tree_status == "M" }
      end
    end

    # Represents the branches in a git repository
    #
    # @example
    #   branches = sandbox.git.branches("/home/user/repo")
    #   puts "Current: #{branches.current}"
    #   puts "Local: #{branches.local.join(', ')}"
    class GitBranches
      # @return [String, nil] The currently checked-out branch
      attr_reader :current

      # @return [Array<String>] List of local branch names
      attr_reader :local

      # @return [Array<String>] List of remote branch names
      attr_reader :remote

      # @param current [String, nil] Current branch name
      # @param local [Array<String>] Local branch names
      # @param remote [Array<String>] Remote branch names
      def initialize(current: nil, local: [], remote: [])
        @current = current
        @local = local
        @remote = remote
      end
    end

    # Git operations service for E2B sandbox
    #
    # Runs git CLI commands inside the sandbox by delegating to the Commands service.
    # Does not use RPC directly - all operations are performed via shell commands.
    #
    # @example
    #   sandbox.git.clone("https://github.com/user/repo.git", path: "/home/user/repo")
    #   sandbox.git.add("/home/user/repo")
    #   sandbox.git.commit("/home/user/repo", "Initial commit", author_name: "Bot", author_email: "bot@example.com")
    #   sandbox.git.push("/home/user/repo")
    class Git
      # Default environment variables applied to all git commands
      DEFAULT_GIT_ENV = { "GIT_TERMINAL_PROMPT" => "0" }.freeze

      # Default timeout for git operations in seconds
      DEFAULT_TIMEOUT = 300

      # Valid git config scopes
      VALID_SCOPES = %w[global local system].freeze

      # @param commands [E2B::Services::Commands] The commands service instance
      def initialize(commands:)
        @commands = commands
      end

      # Clone a git repository
      #
      # @param url [String] Repository URL to clone
      # @param path [String, nil] Destination path; if nil, git chooses the directory name
      # @param branch [String, nil] Branch to checkout after cloning
      # @param depth [Integer, nil] Create a shallow clone with the given depth
      # @param username [String, nil] Username for authentication
      # @param password [String, nil] Password or token for authentication
      # @param envs [Hash{String => String}, nil] Additional environment variables
      # @param user [String, nil] User context (reserved for future use)
      # @param cwd [String, nil] Working directory for the clone command
      # @param timeout [Integer, nil] Command timeout in seconds
      # @return [E2B::Models::ProcessResult] Command result
      # @raise [E2B::GitAuthError] If authentication fails
      def clone(url, path: nil, branch: nil, depth: nil, username: nil, password: nil,
                envs: nil, user: nil, cwd: nil, timeout: nil)
        clone_url = if username && password
                      with_credentials(url, username, password)
                    else
                      url
                    end

        args = ["clone"]
        args += ["--branch", branch] if branch
        args += ["--depth", depth.to_s] if depth
        args << Shellwords.escape(clone_url)
        args << Shellwords.escape(path) if path

        result = run_git(args, nil, envs: envs, user: user, cwd: cwd, timeout: timeout)
        check_auth_failure!(result)
        result
      end

      # Initialize a new git repository
      #
      # @param path [String] Path where the repository should be initialized
      # @param bare [Boolean] Create a bare repository
      # @param initial_branch [String, nil] Name for the initial branch
      # @param envs [Hash{String => String}, nil] Additional environment variables
      # @param user [String, nil] User context (reserved for future use)
      # @param cwd [String, nil] Working directory
      # @param timeout [Integer, nil] Command timeout in seconds
      # @return [E2B::Models::ProcessResult] Command result
      def init(path, bare: false, initial_branch: nil, envs: nil, user: nil, cwd: nil, timeout: nil)
        args = ["init"]
        args << "--bare" if bare
        args += ["--initial-branch", initial_branch] if initial_branch
        args << Shellwords.escape(path)

        run_git(args, nil, envs: envs, user: user, cwd: cwd, timeout: timeout)
      end

      # Add a remote to a repository
      #
      # @param path [String] Repository path
      # @param name [String] Remote name (e.g., "origin")
      # @param url [String] Remote URL
      # @param fetch [Boolean] Fetch from the remote after adding
      # @param overwrite [Boolean] If true, set-url on an existing remote instead of failing
      # @param envs [Hash{String => String}, nil] Additional environment variables
      # @param user [String, nil] User context (reserved for future use)
      # @param cwd [String, nil] Working directory
      # @param timeout [Integer, nil] Command timeout in seconds
      # @return [E2B::Models::ProcessResult] Command result
      def remote_add(path, name, url, fetch: false, overwrite: false, envs: nil, user: nil, cwd: nil, timeout: nil)
        if overwrite
          # Check if remote already exists
          existing = remote_get(path, name, envs: envs, user: user, cwd: cwd, timeout: timeout)
          if existing
            args = ["remote", "set-url", name, Shellwords.escape(url)]
            result = run_git(args, path, envs: envs, user: user, cwd: cwd, timeout: timeout)
          else
            args = ["remote", "add", name, Shellwords.escape(url)]
            result = run_git(args, path, envs: envs, user: user, cwd: cwd, timeout: timeout)
          end
        else
          args = ["remote", "add", name, Shellwords.escape(url)]
          result = run_git(args, path, envs: envs, user: user, cwd: cwd, timeout: timeout)
        end

        if fetch
          fetch_args = ["fetch", name]
          run_git(fetch_args, path, envs: envs, user: user, cwd: cwd, timeout: timeout)
        end

        result
      end

      # Get the URL of a named remote
      #
      # @param path [String] Repository path
      # @param name [String] Remote name (e.g., "origin")
      # @param envs [Hash{String => String}, nil] Additional environment variables
      # @param user [String, nil] User context (reserved for future use)
      # @param cwd [String, nil] Working directory
      # @param timeout [Integer, nil] Command timeout in seconds
      # @return [String, nil] Remote URL, or nil if the remote does not exist
      def remote_get(path, name, envs: nil, user: nil, cwd: nil, timeout: nil)
        args = ["remote", "get-url", name]
        result = run_git(args, path, envs: envs, user: user, cwd: cwd, timeout: timeout)
        return nil unless result.success?

        url = result.stdout.strip
        url.empty? ? nil : url
      end

      # Get the status of a git repository
      #
      # @param path [String] Repository path
      # @param envs [Hash{String => String}, nil] Additional environment variables
      # @param user [String, nil] User context (reserved for future use)
      # @param cwd [String, nil] Working directory
      # @param timeout [Integer, nil] Command timeout in seconds
      # @return [GitStatus] Parsed status information
      def status(path, envs: nil, user: nil, cwd: nil, timeout: nil)
        args = ["status", "--porcelain=v2", "--branch"]
        result = run_git(args, path, envs: envs, user: user, cwd: cwd, timeout: timeout)
        parse_status(result.stdout)
      end

      # List all branches (local and remote)
      #
      # @param path [String] Repository path
      # @param envs [Hash{String => String}, nil] Additional environment variables
      # @param user [String, nil] User context (reserved for future use)
      # @param cwd [String, nil] Working directory
      # @param timeout [Integer, nil] Command timeout in seconds
      # @return [GitBranches] Parsed branch information
      def branches(path, envs: nil, user: nil, cwd: nil, timeout: nil)
        args = ["branch", "-a", "--format=%(refname:short) %(HEAD)"]
        result = run_git(args, path, envs: envs, user: user, cwd: cwd, timeout: timeout)
        parse_branches(result.stdout)
      end

      # Create a new branch
      #
      # @param path [String] Repository path
      # @param branch [String] Branch name to create
      # @param envs [Hash{String => String}, nil] Additional environment variables
      # @param user [String, nil] User context (reserved for future use)
      # @param cwd [String, nil] Working directory
      # @param timeout [Integer, nil] Command timeout in seconds
      # @return [E2B::Models::ProcessResult] Command result
      def create_branch(path, branch, envs: nil, user: nil, cwd: nil, timeout: nil)
        args = ["branch", branch]
        run_git(args, path, envs: envs, user: user, cwd: cwd, timeout: timeout)
      end

      # Checkout an existing branch
      #
      # @param path [String] Repository path
      # @param branch [String] Branch name to checkout
      # @param envs [Hash{String => String}, nil] Additional environment variables
      # @param user [String, nil] User context (reserved for future use)
      # @param cwd [String, nil] Working directory
      # @param timeout [Integer, nil] Command timeout in seconds
      # @return [E2B::Models::ProcessResult] Command result
      def checkout_branch(path, branch, envs: nil, user: nil, cwd: nil, timeout: nil)
        args = ["checkout", branch]
        run_git(args, path, envs: envs, user: user, cwd: cwd, timeout: timeout)
      end

      # Delete a branch
      #
      # @param path [String] Repository path
      # @param branch [String] Branch name to delete
      # @param force [Boolean] Force-delete the branch (even if not fully merged)
      # @param envs [Hash{String => String}, nil] Additional environment variables
      # @param user [String, nil] User context (reserved for future use)
      # @param cwd [String, nil] Working directory
      # @param timeout [Integer, nil] Command timeout in seconds
      # @return [E2B::Models::ProcessResult] Command result
      def delete_branch(path, branch, force: false, envs: nil, user: nil, cwd: nil, timeout: nil)
        flag = force ? "-D" : "-d"
        args = ["branch", flag, branch]
        run_git(args, path, envs: envs, user: user, cwd: cwd, timeout: timeout)
      end

      # Stage files for commit
      #
      # @param path [String] Repository path
      # @param files [Array<String>, nil] Specific files to stage; ignored when +all+ is true
      # @param all [Boolean] Stage all changes (tracked and untracked)
      # @param envs [Hash{String => String}, nil] Additional environment variables
      # @param user [String, nil] User context (reserved for future use)
      # @param cwd [String, nil] Working directory
      # @param timeout [Integer, nil] Command timeout in seconds
      # @return [E2B::Models::ProcessResult] Command result
      def add(path, files: nil, all: true, envs: nil, user: nil, cwd: nil, timeout: nil)
        args = ["add"]
        if all
          args << "-A"
        elsif files && !files.empty?
          files.each { |f| args << Shellwords.escape(f) }
        else
          args << "-A"
        end

        run_git(args, path, envs: envs, user: user, cwd: cwd, timeout: timeout)
      end

      # Create a commit
      #
      # @param path [String] Repository path
      # @param message [String] Commit message
      # @param author_name [String, nil] Author name (overrides git config)
      # @param author_email [String, nil] Author email (overrides git config)
      # @param allow_empty [Boolean] Allow creating a commit with no changes
      # @param envs [Hash{String => String}, nil] Additional environment variables
      # @param user [String, nil] User context (reserved for future use)
      # @param cwd [String, nil] Working directory
      # @param timeout [Integer, nil] Command timeout in seconds
      # @return [E2B::Models::ProcessResult] Command result
      def commit(path, message, author_name: nil, author_email: nil, allow_empty: false,
                 envs: nil, user: nil, cwd: nil, timeout: nil)
        args = ["commit", "-m", Shellwords.escape(message)]
        args << "--allow-empty" if allow_empty

        commit_envs = (envs || {}).dup
        if author_name && author_email
          commit_envs["GIT_AUTHOR_NAME"] = author_name
          commit_envs["GIT_COMMITTER_NAME"] = author_name
          commit_envs["GIT_AUTHOR_EMAIL"] = author_email
          commit_envs["GIT_COMMITTER_EMAIL"] = author_email
        end

        run_git(args, path, envs: commit_envs, user: user, cwd: cwd, timeout: timeout)
      end

      # Reset the current HEAD to a specified state
      #
      # @param path [String] Repository path
      # @param mode [String, nil] Reset mode: "soft", "mixed", "hard", "merge", or "keep"
      # @param target [String, nil] Commit, branch, or tag to reset to
      # @param paths [Array<String>, nil] Specific paths to reset (unstage)
      # @param envs [Hash{String => String}, nil] Additional environment variables
      # @param user [String, nil] User context (reserved for future use)
      # @param cwd [String, nil] Working directory
      # @param timeout [Integer, nil] Command timeout in seconds
      # @return [E2B::Models::ProcessResult] Command result
      def reset(path, mode: nil, target: nil, paths: nil, envs: nil, user: nil, cwd: nil, timeout: nil)
        args = ["reset"]
        args << "--#{mode}" if mode
        args << target if target

        if paths && !paths.empty?
          args << "--"
          paths.each { |p| args << Shellwords.escape(p) }
        end

        run_git(args, path, envs: envs, user: user, cwd: cwd, timeout: timeout)
      end

      # Restore working tree files
      #
      # @param path [String] Repository path
      # @param paths [Array<String>] Paths to restore
      # @param staged [Boolean, nil] Restore staged changes (--staged)
      # @param worktree [Boolean, nil] Restore working tree changes (--worktree)
      # @param source [String, nil] Restore from a specific source (commit, branch, etc.)
      # @param envs [Hash{String => String}, nil] Additional environment variables
      # @param user [String, nil] User context (reserved for future use)
      # @param cwd [String, nil] Working directory
      # @param timeout [Integer, nil] Command timeout in seconds
      # @return [E2B::Models::ProcessResult] Command result
      def restore(path, paths, staged: nil, worktree: nil, source: nil, envs: nil, user: nil, cwd: nil, timeout: nil)
        args = ["restore"]
        args << "--staged" if staged
        args << "--worktree" if worktree
        args += ["--source", source] if source

        if paths.is_a?(Array)
          paths.each { |p| args << Shellwords.escape(p) }
        else
          args << Shellwords.escape(paths)
        end

        run_git(args, path, envs: envs, user: user, cwd: cwd, timeout: timeout)
      end

      # Push commits to a remote repository
      #
      # When +username+ and +password+ are provided, the remote URL is temporarily
      # modified to include credentials, then restored after the push completes.
      #
      # @param path [String] Repository path
      # @param remote [String, nil] Remote name (defaults to "origin" by git)
      # @param branch [String, nil] Branch to push
      # @param set_upstream [Boolean] Set the upstream tracking branch (-u)
      # @param username [String, nil] Username for authentication
      # @param password [String, nil] Password or token for authentication
      # @param envs [Hash{String => String}, nil] Additional environment variables
      # @param user [String, nil] User context (reserved for future use)
      # @param cwd [String, nil] Working directory
      # @param timeout [Integer, nil] Command timeout in seconds
      # @return [E2B::Models::ProcessResult] Command result
      # @raise [E2B::GitAuthError] If authentication fails
      # @raise [E2B::GitUpstreamError] If no upstream is configured and cannot be determined
      def push(path, remote: nil, branch: nil, set_upstream: true, username: nil, password: nil,
               envs: nil, user: nil, cwd: nil, timeout: nil)
        effective_remote = remote || "origin"

        if username && password
          with_authenticated_remote(path, effective_remote, username, password,
                                    envs: envs, user: user, cwd: cwd, timeout: timeout) do
            do_push(path, effective_remote, branch, set_upstream,
                    envs: envs, user: user, cwd: cwd, timeout: timeout)
          end
        else
          do_push(path, effective_remote, branch, set_upstream,
                  envs: envs, user: user, cwd: cwd, timeout: timeout)
        end
      end

      # Pull changes from a remote repository
      #
      # When +username+ and +password+ are provided, the remote URL is temporarily
      # modified to include credentials, then restored after the pull completes.
      #
      # @param path [String] Repository path
      # @param remote [String, nil] Remote name (defaults to "origin" by git)
      # @param branch [String, nil] Branch to pull
      # @param username [String, nil] Username for authentication
      # @param password [String, nil] Password or token for authentication
      # @param envs [Hash{String => String}, nil] Additional environment variables
      # @param user [String, nil] User context (reserved for future use)
      # @param cwd [String, nil] Working directory
      # @param timeout [Integer, nil] Command timeout in seconds
      # @return [E2B::Models::ProcessResult] Command result
      # @raise [E2B::GitAuthError] If authentication fails
      def pull(path, remote: nil, branch: nil, username: nil, password: nil,
               envs: nil, user: nil, cwd: nil, timeout: nil)
        effective_remote = remote || "origin"

        if username && password
          with_authenticated_remote(path, effective_remote, username, password,
                                    envs: envs, user: user, cwd: cwd, timeout: timeout) do
            do_pull(path, effective_remote, branch,
                    envs: envs, user: user, cwd: cwd, timeout: timeout)
          end
        else
          do_pull(path, effective_remote, branch,
                  envs: envs, user: user, cwd: cwd, timeout: timeout)
        end
      end

      # Set a git configuration value
      #
      # @param key [String] Configuration key (e.g., "user.name")
      # @param value [String] Configuration value
      # @param scope [String] Config scope: "global", "local", or "system"
      # @param path [String, nil] Repository path (required for "local" scope)
      # @param envs [Hash{String => String}, nil] Additional environment variables
      # @param user [String, nil] User context (reserved for future use)
      # @param cwd [String, nil] Working directory
      # @param timeout [Integer, nil] Command timeout in seconds
      # @return [E2B::Models::ProcessResult] Command result
      # @raise [E2B::E2BError] If the scope is invalid
      def set_config(key, value, scope: "global", path: nil, envs: nil, user: nil, cwd: nil, timeout: nil)
        validate_scope!(scope)

        args = ["config", scope_flag(scope), key, Shellwords.escape(value)]
        run_git(args, path, envs: envs, user: user, cwd: cwd, timeout: timeout)
      end

      # Get a git configuration value
      #
      # @param key [String] Configuration key (e.g., "user.name")
      # @param scope [String] Config scope: "global", "local", or "system"
      # @param path [String, nil] Repository path (required for "local" scope)
      # @param envs [Hash{String => String}, nil] Additional environment variables
      # @param user [String, nil] User context (reserved for future use)
      # @param cwd [String, nil] Working directory
      # @param timeout [Integer, nil] Command timeout in seconds
      # @return [String, nil] Configuration value, or nil if not set
      def get_config(key, scope: "global", path: nil, envs: nil, user: nil, cwd: nil, timeout: nil)
        validate_scope!(scope)

        args = ["config", scope_flag(scope), "--get", key]
        result = run_git(args, path, envs: envs, user: user, cwd: cwd, timeout: timeout)
        return nil unless result.success?

        value = result.stdout.strip
        value.empty? ? nil : value
      end

      # Configure a credential helper that accepts any credentials without prompting
      #
      # WARNING: This stores credentials in plaintext in the git credential store.
      # Use only in sandbox environments where security of stored credentials is acceptable.
      #
      # @param username [String] Username for authentication
      # @param password [String] Password or token for authentication
      # @param host [String] Host to authenticate against (default: "github.com")
      # @param protocol [String] Protocol to use (default: "https")
      # @param envs [Hash{String => String}, nil] Additional environment variables
      # @param user [String, nil] User context (reserved for future use)
      # @param cwd [String, nil] Working directory
      # @param timeout [Integer, nil] Command timeout in seconds
      # @return [E2B::Models::ProcessResult] Command result
      def dangerously_authenticate(username, password, host: "github.com", protocol: "https",
                                   envs: nil, user: nil, cwd: nil, timeout: nil)
        # Configure credential helper to use the store
        set_config("credential.helper", "store", scope: "global",
                   envs: envs, user: user, cwd: cwd, timeout: timeout)

        # Write credentials to the credential store via git credential approve
        credential_input = [
          "protocol=#{protocol}",
          "host=#{host}",
          "username=#{username}",
          "password=#{password}",
          ""
        ].join("\n")

        escaped_input = Shellwords.escape(credential_input)
        args = ["credential", "approve"]
        cmd = build_git_command(args, nil)
        full_cmd = "echo #{escaped_input} | #{cmd}"

        merged_envs = DEFAULT_GIT_ENV.merge(envs || {})
        @commands.run(full_cmd, cwd: cwd, envs: merged_envs, timeout: timeout || DEFAULT_TIMEOUT)
      end

      # Configure the git user name and email
      #
      # @param name [String] User name for commits
      # @param email [String] User email for commits
      # @param scope [String] Config scope: "global", "local", or "system"
      # @param path [String, nil] Repository path (required for "local" scope)
      # @param envs [Hash{String => String}, nil] Additional environment variables
      # @param user [String, nil] User context (reserved for future use)
      # @param cwd [String, nil] Working directory
      # @param timeout [Integer, nil] Command timeout in seconds
      # @return [void]
      def configure_user(name, email, scope: "global", path: nil, envs: nil, user: nil, cwd: nil, timeout: nil)
        set_config("user.name", name, scope: scope, path: path,
                   envs: envs, user: user, cwd: cwd, timeout: timeout)
        set_config("user.email", email, scope: scope, path: path,
                   envs: envs, user: user, cwd: cwd, timeout: timeout)
      end

      private

      # Run a git command through the Commands service
      #
      # @param args [Array<String>] Git subcommand and arguments
      # @param repo_path [String, nil] Repository path to pass via -C
      # @param envs [Hash{String => String}, nil] Additional environment variables
      # @param user [String, nil] User context (reserved for future use)
      # @param cwd [String, nil] Working directory
      # @param timeout [Integer, nil] Command timeout in seconds
      # @return [E2B::Models::ProcessResult] Command result
      def run_git(args, repo_path = nil, envs: nil, user: nil, cwd: nil, timeout: nil)
        cmd = build_git_command(args, repo_path)
        merged_envs = DEFAULT_GIT_ENV.merge(envs || {})
        @commands.run(cmd, cwd: cwd, envs: merged_envs, timeout: timeout || DEFAULT_TIMEOUT)
      end

      # Build a complete git command string
      #
      # @param args [Array<String>] Git subcommand and arguments
      # @param repo_path [String, nil] Repository path to pass via -C
      # @return [String] Complete command string
      def build_git_command(args, repo_path)
        parts = ["git"]
        parts += ["-C", Shellwords.escape(repo_path)] if repo_path
        parts += args
        parts.join(" ")
      end

      # Execute a push operation
      #
      # @param path [String] Repository path
      # @param remote [String] Remote name
      # @param branch [String, nil] Branch to push
      # @param set_upstream [Boolean] Whether to set the upstream tracking branch
      # @param envs [Hash{String => String}, nil] Additional environment variables
      # @param user [String, nil] User context
      # @param cwd [String, nil] Working directory
      # @param timeout [Integer, nil] Command timeout in seconds
      # @return [E2B::Models::ProcessResult] Command result
      def do_push(path, remote, branch, set_upstream, envs: nil, user: nil, cwd: nil, timeout: nil)
        args = ["push"]
        args << "-u" if set_upstream
        args << remote
        args << branch if branch

        result = run_git(args, path, envs: envs, user: user, cwd: cwd, timeout: timeout)
        check_auth_failure!(result)
        check_upstream_failure!(result)
        result
      end

      # Execute a pull operation
      #
      # @param path [String] Repository path
      # @param remote [String] Remote name
      # @param branch [String, nil] Branch to pull
      # @param envs [Hash{String => String}, nil] Additional environment variables
      # @param user [String, nil] User context
      # @param cwd [String, nil] Working directory
      # @param timeout [Integer, nil] Command timeout in seconds
      # @return [E2B::Models::ProcessResult] Command result
      def do_pull(path, remote, branch, envs: nil, user: nil, cwd: nil, timeout: nil)
        args = ["pull"]
        args << remote
        args << branch if branch

        result = run_git(args, path, envs: envs, user: user, cwd: cwd, timeout: timeout)
        check_auth_failure!(result)
        result
      end

      # Temporarily set credentials on a remote URL, execute a block, then restore the original URL
      #
      # @param path [String] Repository path
      # @param remote [String] Remote name
      # @param username [String] Username for authentication
      # @param password [String] Password or token for authentication
      # @param envs [Hash{String => String}, nil] Additional environment variables
      # @param user [String, nil] User context
      # @param cwd [String, nil] Working directory
      # @param timeout [Integer, nil] Command timeout in seconds
      # @yield Block to execute with credentials set on the remote URL
      # @return [Object] Result of the block
      def with_authenticated_remote(path, remote, username, password, envs: nil, user: nil, cwd: nil, timeout: nil)
        # Get current remote URL
        original_url = remote_get(path, remote, envs: envs, user: user, cwd: cwd, timeout: timeout)
        raise E2B::E2BError, "Remote '#{remote}' not found in repository" unless original_url

        # Set authenticated URL
        authenticated_url = with_credentials(original_url, username, password)
        set_url_args = ["remote", "set-url", remote, Shellwords.escape(authenticated_url)]
        run_git(set_url_args, path, envs: envs, user: user, cwd: cwd, timeout: timeout)

        begin
          yield
        ensure
          # Restore original URL (without credentials)
          clean_url = strip_credentials(original_url)
          restore_args = ["remote", "set-url", remote, Shellwords.escape(clean_url)]
          run_git(restore_args, path, envs: envs, user: user, cwd: cwd, timeout: timeout)
        end
      end

      # Embed credentials into a URL
      #
      # @param url [String] Original URL
      # @param username [String] Username
      # @param password [String] Password or token
      # @return [String] URL with embedded credentials
      def with_credentials(url, username, password)
        uri = URI.parse(url)
        uri.user = URI.encode_www_form_component(username)
        uri.password = URI.encode_www_form_component(password)
        uri.to_s
      rescue URI::InvalidURIError
        # Fallback for URLs that URI cannot parse (e.g., git@ SSH URLs)
        url
      end

      # Remove credentials from a URL
      #
      # @param url [String] URL potentially containing credentials
      # @return [String] URL without credentials
      def strip_credentials(url)
        uri = URI.parse(url)
        uri.user = nil
        uri.password = nil
        uri.to_s
      rescue URI::InvalidURIError
        url
      end

      # Check if a command result indicates an authentication failure
      #
      # @param result [E2B::Models::ProcessResult] Command result to check
      # @raise [E2B::GitAuthError] If authentication failure is detected
      def check_auth_failure!(result)
        return if result.success?

        stderr = result.stderr.to_s
        if stderr.include?("Authentication failed") ||
           stderr.include?("could not read Username") ||
           stderr.include?("terminal prompts disabled") ||
           stderr.match?(/fatal:.*403/) ||
           stderr.include?("Invalid username or password")
          raise E2B::GitAuthError, "Git authentication failed: #{stderr.strip}"
        end
      end

      # Check if a command result indicates an upstream configuration failure
      #
      # @param result [E2B::Models::ProcessResult] Command result to check
      # @raise [E2B::GitUpstreamError] If upstream failure is detected
      def check_upstream_failure!(result)
        return if result.success?

        stderr = result.stderr.to_s
        if stderr.include?("has no upstream branch") ||
           stderr.include?("no upstream configured") ||
           stderr.include?("does not appear to be a git repository")
          raise E2B::GitUpstreamError, "Git upstream error: #{stderr.strip}"
        end
      end

      # Validate that a scope string is one of the accepted values
      #
      # @param scope [String] Scope to validate
      # @raise [E2B::E2BError] If the scope is not valid
      def validate_scope!(scope)
        return if VALID_SCOPES.include?(scope)

        raise E2B::E2BError, "Invalid git config scope '#{scope}'. Must be one of: #{VALID_SCOPES.join(', ')}"
      end

      # Convert a scope name to its git CLI flag
      #
      # @param scope [String] Scope name ("global", "local", or "system")
      # @return [String] Corresponding git flag
      def scope_flag(scope)
        "--#{scope}"
      end

      # Parse the output of `git status --porcelain=v2 --branch`
      #
      # @param output [String] Raw stdout from git status
      # @return [GitStatus] Parsed status object
      def parse_status(output)
        current_branch = nil
        upstream = nil
        ahead = 0
        behind = 0
        detached = false
        file_status = []

        output.each_line do |line|
          line = line.chomp

          case line
          when /\A# branch\.head (.+)\z/
            head = Regexp.last_match(1)
            if head == "(detached)"
              detached = true
            else
              current_branch = head
            end
          when /\A# branch\.upstream (.+)\z/
            upstream = Regexp.last_match(1)
          when /\A# branch\.ab \+(\d+) -(\d+)\z/
            ahead = Regexp.last_match(1).to_i
            behind = Regexp.last_match(2).to_i
          when /\A1 (.)(.) .+ .+ .+ .+ .+ (.+)\z/
            # Ordinary changed entry
            idx = Regexp.last_match(1)
            wt = Regexp.last_match(2)
            filepath = Regexp.last_match(3)
            file_status << GitFileStatus.new(path: filepath, index_status: idx, work_tree_status: wt)
          when /\A2 (.)(.) .+ .+ .+ .+ .+ .+ (.+)\z/
            # Renamed or copied entry (path includes original\ttab\tnew)
            idx = Regexp.last_match(1)
            wt = Regexp.last_match(2)
            filepath = Regexp.last_match(3)
            # The path field for renames is "new_path\told_path"; use the new path
            file_status << GitFileStatus.new(path: filepath.split("\t").first, index_status: idx, work_tree_status: wt)
          when /\Au (.)(.) .+ .+ .+ .+ .+ (.+)\z/
            # Unmerged entry
            idx = Regexp.last_match(1)
            wt = Regexp.last_match(2)
            filepath = Regexp.last_match(3)
            file_status << GitFileStatus.new(path: filepath, index_status: "u", work_tree_status: wt)
          when /\A\? (.+)\z/
            # Untracked file
            filepath = Regexp.last_match(1)
            file_status << GitFileStatus.new(path: filepath, index_status: "?", work_tree_status: "?")
          end
        end

        GitStatus.new(
          current_branch: current_branch,
          upstream: upstream,
          ahead: ahead,
          behind: behind,
          detached: detached,
          file_status: file_status
        )
      end

      # Parse the output of `git branch -a --format="%(refname:short) %(HEAD)"`
      #
      # @param output [String] Raw stdout from git branch
      # @return [GitBranches] Parsed branch information
      def parse_branches(output)
        current = nil
        local = []
        remote = []

        output.each_line do |line|
          line = line.chomp.strip
          next if line.empty?

          # Format: "branch_name *" for current, "branch_name " for others
          # Remote branches appear as "origin/branch_name"
          if line.end_with?("*")
            branch_name = line.sub(/\s*\*\s*\z/, "").strip
            current = branch_name
            local << branch_name unless branch_name.include?("/")
          else
            branch_name = line.strip
            if branch_name.include?("/")
              # Skip HEAD pointer entries like "origin/HEAD"
              remote << branch_name unless branch_name.end_with?("/HEAD")
            else
              local << branch_name
            end
          end
        end

        GitBranches.new(current: current, local: local, remote: remote)
      end
    end
  end
end
