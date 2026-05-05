# E2B Ruby SDK

[![Gem Version](https://badge.fury.io/rb/e2b.svg)](https://badge.fury.io/rb/e2b)

Ruby SDK for [E2B](https://e2b.dev) - secure cloud sandboxes for AI-generated code execution.

Aligned with the [official E2B SDKs](https://github.com/e2b-dev/E2B) (Python/JS).

## Features

- Sandbox lifecycle management (create, connect, pause, resume, kill)
- Command execution with streaming output and background processes
- Filesystem operations via proper envd RPC (list, read, write, stat, watch)
- PTY (pseudo-terminal) support for interactive sessions
- Git operations (clone, push, pull, branches, status, commit, etc.)
- Directory watching with event polling
- Snapshot support (create, list, delete)
- Template builds (Dockerfile-style DSL, registry auth, build logs)
- Sandbox metrics & logs
- MCP gateway integration
- Backward-compatible Client class

## Installation

```bash
gem install e2b
```

Or add to your Gemfile:

```ruby
gem 'e2b'
```

Then:

```bash
bundle install
```

## Quick Start

```ruby
require 'e2b'

# Create a sandbox (matches official SDK pattern)
sandbox = E2B::Sandbox.create(template: "base", api_key: ENV['E2B_API_KEY'])

# Run commands
result = sandbox.commands.run('echo "Hello from E2B!"')
puts result.stdout

# Work with files
sandbox.files.write('/home/user/hello.txt', 'Hello, World!')
content = sandbox.files.read('/home/user/hello.txt')

# List directory (returns EntryInfo objects)
entries = sandbox.files.list('/home/user')
entries.each { |e| puts "#{e.name} (#{e.type}, #{e.size} bytes)" }

# Background commands
handle = sandbox.commands.run("sleep 30", background: true)
handle.kill

# PTY (interactive terminal)
handle = sandbox.pty.create
handle.send_stdin("ls -la\n")
handle.kill

# Git operations
sandbox.git.clone("https://github.com/user/repo.git", path: "/home/user/repo")
status = sandbox.git.status("/home/user/repo")
puts "Branch: #{status.current_branch}, Clean: #{status.clean?}"

# Sandbox lifecycle
sandbox.set_timeout(600)  # extend by 10 minutes
sandbox.pause
sandbox.resume(timeout: 300)

# Clean up
sandbox.kill
```

## Configuration

```bash
# Option 1: Environment variables (recommended)
export E2B_API_KEY=your-api-key
# Optional:
export E2B_ACCESS_TOKEN=your-access-token  # alternative auth
export E2B_DOMAIN=e2b.app                  # custom domain
export E2B_API_URL=https://api.e2b.app     # custom API URL
export E2B_DEBUG=true                      # enable debug logging
```

```ruby
# Option 2: Global configuration
E2B.configure do |config|
  config.api_key = 'your-api-key'
  config.domain = 'e2b.app'
end

# Option 3: Per-call (api_key or access_token)
sandbox = E2B::Sandbox.create(template: "base", api_key: "your-key")
sandbox = E2B::Sandbox.create(template: "base", access_token: "your-token")

# Option 4: Client class (backward compatible)
client = E2B::Client.new(api_key: "your-key")
sandbox = client.create(template: "base")
```

## API Reference

### Sandbox (class methods)

| Method | Description |
|--------|-------------|
| `Sandbox.create(template:, timeout:, metadata:, envs:, secure:, allow_internet_access:, mcp:, api_key:)` | Create a new sandbox |
| `Sandbox.connect(sandbox_id, timeout:, api_key:)` | Connect to an existing sandbox |
| `Sandbox.list(query:, limit:, next_token:, api_key:)` | List running sandboxes (returns `SandboxPaginator`) |
| `Sandbox.kill(sandbox_id, api_key:)` | Kill a sandbox by ID (idempotent) |
| `Sandbox.list_snapshots(sandbox_id:, limit:, next_token:, api_key:)` | List snapshots (returns `SnapshotPaginator`) |
| `Sandbox.delete_snapshot(snapshot_id, api_key:)` | Delete a snapshot template |

### Sandbox (instance)

| Method | Description |
|--------|-------------|
| `sandbox.commands` | Command execution service |
| `sandbox.files` | Filesystem service |
| `sandbox.pty` | PTY (terminal) service |
| `sandbox.git` | Git operations service |
| `sandbox.get_info` | Refresh and return sandbox info from API |
| `sandbox.running?` | Check whether sandbox is currently running |
| `sandbox.set_timeout(seconds)` | Extend sandbox lifetime |
| `sandbox.time_remaining` | Seconds until timeout (0 if expired/unknown) |
| `sandbox.get_host(port)` / `sandbox.get_url(port)` | Get host string / full URL for a port |
| `sandbox.download_url(path, user:)` / `sandbox.upload_url(path, user:)` | Pre-signed file URLs |
| `sandbox.pause` / `sandbox.resume(timeout:)` | Pause/resume sandbox |
| `sandbox.create_snapshot` | Create sandbox snapshot (returns `SnapshotInfo`) |
| `sandbox.list_snapshots(limit:, next_token:)` | List snapshots from this sandbox |
| `sandbox.get_metrics(start_time:, end_time:)` | CPU / memory / disk metrics |
| `sandbox.logs(start_time:, limit:)` | Sandbox logs |
| `sandbox.get_mcp_url` / `sandbox.get_mcp_token` | MCP gateway URL and token (when `mcp:` enabled) |
| `sandbox.kill` | Terminate sandbox (idempotent) |

### Commands (`sandbox.commands`)

| Method | Description |
|--------|-------------|
| `run(cmd, background:, envs:, user:, cwd:, timeout:, request_timeout:, stdin:, on_stdout:, on_stderr:)` | Run command (returns `CommandResult` or `CommandHandle`). `timeout` is the command timeout (seconds, default 60); `request_timeout` is the HTTP request timeout. Pass `stdin: true` if you plan to call `send_stdin` on a background handle. |
| `list` | List running processes |
| `kill(pid)` | Kill a process |
| `send_stdin(pid, data)` | Send stdin to a process |
| `close_stdin(pid)` | Close stdin (send EOF) |
| `connect(pid, timeout:)` | Connect to a running process |

### Filesystem (`sandbox.files`)

| Method | Description |
|--------|-------------|
| `read(path, format:)` | Read file content (`format:` `"text"` (default), `"bytes"`, or `"stream"`) |
| `write(path, data)` | Write file (via REST upload, returns `WriteInfo`) |
| `write_files(files)` | Write multiple files |
| `list(path, depth:)` | List directory (returns `EntryInfo[]`) |
| `get_info(path)` | Get file/dir info (returns `EntryInfo`) |
| `exists?(path)` | Check if path exists |
| `make_dir(path)` | Create directory |
| `remove(path)` | Remove file/directory |
| `rename(old_path, new_path)` | Rename/move |
| `watch_dir(path, recursive:)` | Watch directory (returns `WatchHandle`) |

### PTY (`sandbox.pty`)

| Method | Description |
|--------|-------------|
| `create(size:, cwd:, envs:)` | Create PTY session (returns `CommandHandle`) |
| `connect(pid)` | Connect to existing PTY |
| `send_stdin(pid, data)` | Send input to PTY |
| `kill(pid)` | Kill PTY process |
| `resize(pid, size)` | Resize terminal |
| `close_stdin(pid)` | Close PTY stdin (send EOF) |
| `list` | List running processes |

### Git (`sandbox.git`)

| Method | Description |
|--------|-------------|
| `clone(url, path:, branch:, depth:, username:, password:)` | Clone repository |
| `init(path, bare:, initial_branch:)` | Initialize repository |
| `status(path)` | Get repo status (returns `GitStatus`) |
| `branches(path)` | List branches (returns `GitBranches`) |
| `add(path, files:, all:)` | Stage files |
| `commit(path, message, author_name:, author_email:)` | Create commit |
| `push(path, remote:, branch:, username:, password:)` | Push to remote |
| `pull(path, remote:, branch:, username:, password:)` | Pull from remote |
| `create_branch` / `checkout_branch` / `delete_branch` | Branch management |
| `remote_add(path, name, url)` / `remote_get(path, name)` | Remote management |
| `reset(path, mode:, target:)` / `restore(path, paths)` | Reset/restore changes |
| `set_config` / `get_config` | Git configuration |
| `configure_user(name, email)` | Set user name/email |
| `dangerously_authenticate(username, password)` | Store credentials globally |

### Templates (`E2B::Template`)

Build custom sandbox templates using a Dockerfile-style DSL, then build them
on E2B's infrastructure.

```ruby
template = E2B::Template.new
  .from_python_image("3.12")
  .pip_install(["requests", "pandas"])
  .run_cmd("apt-get update && apt-get install -y curl")
  .copy("./app", "/app")
  .set_workdir("/app")
  .set_envs("MY_ENV" => "value")

# Build (blocks until finished)
build_info = E2B::Template.build(
  template,
  alias_name: "my-template",
  cpu_count: 2,
  memory_mb: 1024,
  disk_size_mb: 2048,
  on_build_logs: ->(entry) { puts entry.message }
)

# Or build asynchronously
build_info = E2B::Template.build_in_background(template, alias_name: "my-template")
status = E2B::Template.get_build_status(build_info)
E2B::Template.wait_for_build_finish(build_info)

# Use the built template
sandbox = E2B::Sandbox.create(template: "my-template")
```

| Method | Description |
|--------|-------------|
| `Template.new(file_context_path:, file_ignore_patterns:)` | Start a new template definition |
| `from_image(image, username:, password:)` | Use a custom base image (with optional registry auth) |
| `from_debian_image` / `from_ubuntu_image` / `from_python_image` / `from_node_image` / `from_bun_image` / `from_base_image` | Convenience base-image helpers |
| `from_aws_registry(image, ...)` / `from_gcp_registry(image, ...)` | Pull base from AWS ECR / GCP Artifact Registry |
| `from_dockerfile(content_or_path)` | Initialize from a Dockerfile |
| `from_template(template)` | Inherit from an existing template |
| `copy(src, dest, ...)` / `copy_items(items)` | Copy files into the image |
| `run_cmd(cmd, user:)` | Run a build-time command |
| `set_workdir(path)` / `set_user(user)` / `set_envs(envs)` | Image config |
| `pip_install` / `npm_install` / `bun_install` / `apt_install` | Package manager helpers |
| `add_mcp_server(servers)` | Register MCP servers in the template |
| `git_clone(url, path, branch:, depth:, user:)` | Clone repo at build time |
| `remove(path, ...)` / `rename(src, dest, ...)` / `make_dir(path, ...)` / `make_symlink(src, dest, ...)` | Filesystem ops |
| `set_start_cmd(cmd, ready_cmd)` / `set_ready_cmd(ready_cmd)` | Process start / readiness checks |
| `skip_cache` | Force-rebuild the next layer |
| `Template.build(template, name:, alias_name:, tags:, cpu_count:, memory_mb:, disk_size_mb:, skip_cache:, on_build_logs:)` | Build template (blocks) |
| `Template.build_in_background(template, ...)` | Start a build, return `BuildInfo` |
| `Template.get_build_status(build_info, logs_offset:)` | Poll build status |
| `Template.wait_for_build_finish(build_info, on_build_logs:)` | Block until build completes |
| `Template.exists(name)` / `Template.alias_exists(alias)` | Check template existence |
| `Template.assign_tags(name, tags)` / `Template.remove_tags(name, tags)` / `Template.get_tags(template_id)` | Tag management |
| `Template.to_dockerfile(template)` / `Template.to_json(template)` | Serialize a template definition |

## License

MIT
