# E2B Ruby SDK

Ruby SDK for [E2B](https://e2b.dev) - secure cloud sandboxes for AI-generated code execution.

Aligned with the [official E2B SDKs](https://github.com/e2b-dev/E2B) (Python/JS).

## Features

- Sandbox lifecycle management (create, connect, pause, resume, kill)
- Command execution with streaming output and background processes
- Filesystem operations via proper envd RPC (list, read, write, stat, watch)
- PTY (pseudo-terminal) support for interactive sessions
- Git operations (clone, push, pull, branches, status, commit, etc.)
- Directory watching with event polling
- Snapshot support
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
# Option 1: Environment variable (recommended)
export E2B_API_KEY=your-api-key
```

```ruby
# Option 2: Global configuration
E2B.configure do |config|
  config.api_key = 'your-api-key'
  config.domain = 'e2b.app'
end

# Option 3: Per-call
sandbox = E2B::Sandbox.create(template: "base", api_key: "your-key")

# Option 4: Client class (backward compatible)
client = E2B::Client.new(api_key: "your-key")
sandbox = client.create(template: "base")
```

## API Reference

### Sandbox (class methods)

| Method | Description |
|--------|-------------|
| `Sandbox.create(template:, timeout:, metadata:, envs:, api_key:)` | Create a new sandbox |
| `Sandbox.connect(sandbox_id, timeout:, api_key:)` | Connect to existing sandbox |
| `Sandbox.list(query:, limit:, api_key:)` | List running sandboxes |
| `Sandbox.kill(sandbox_id, api_key:)` | Kill a sandbox by ID |

### Sandbox (instance)

| Method | Description |
|--------|-------------|
| `sandbox.commands` | Command execution service |
| `sandbox.files` | Filesystem service |
| `sandbox.pty` | PTY (terminal) service |
| `sandbox.git` | Git operations service |
| `sandbox.set_timeout(seconds)` | Extend sandbox lifetime |
| `sandbox.get_host(port)` | Get host string for a port |
| `sandbox.get_url(port)` | Get full URL for a port |
| `sandbox.pause` / `sandbox.resume` | Pause/resume sandbox |
| `sandbox.create_snapshot` | Create sandbox snapshot |
| `sandbox.kill` | Terminate sandbox |

### Commands (`sandbox.commands`)

| Method | Description |
|--------|-------------|
| `run(cmd, background:, envs:, cwd:, timeout:, on_stdout:, on_stderr:)` | Run command (returns `CommandResult` or `CommandHandle`) |
| `list` | List running processes |
| `kill(pid)` | Kill a process |
| `send_stdin(pid, data)` | Send stdin to a process |
| `connect(pid)` | Connect to running process |

### Filesystem (`sandbox.files`)

| Method | Description |
|--------|-------------|
| `read(path)` | Read file content |
| `write(path, data)` | Write file (via REST upload) |
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

## License

MIT
