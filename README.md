# E2B Ruby SDK

Unofficial Ruby SDK for [E2B](https://e2b.dev) - secure cloud sandboxes for AI-generated code execution.

## Features

- Create and manage E2B sandboxes
- Execute commands with streaming output
- File system operations (read, write, list, delete)
- Process management
- Custom template support
- Automatic timeout handling

## Installation

Add to your Gemfile:

```ruby
gem 'e2b', git: 'https://github.com/your-org/e2b-ruby.git'
# or from local path
gem 'e2b', path: '../e2b-ruby'
```

Then bundle install:

```bash
bundle install
```

## Quick Start

```ruby
require 'e2b'

# Configure with API key
client = E2B::Client.new(api_key: ENV['E2B_API_KEY'])

# Create a sandbox from a template
sandbox = client.create(template: 'base', timeout_ms: 3_600_000)

# Run commands
result = sandbox.commands.run('echo "Hello from E2B!"')
puts result.stdout

# Work with files
sandbox.files.write('/home/user/hello.txt', 'Hello, World!')
content = sandbox.files.read('/home/user/hello.txt')

# Get public URL for a port
preview_url = sandbox.get_host(4321)

# Keep sandbox alive
sandbox.keep_alive(duration_ms: 3_600_000)

# Clean up
sandbox.kill
```

## Configuration

```ruby
E2B.configure do |config|
  config.api_key = 'your-api-key'
  config.sandbox_timeout_ms = 3_600_000  # 1 hour default
end

client = E2B::Client.new  # Uses global config
```

Or use environment variables:

```bash
export E2B_API_KEY=your-api-key
```

## API Reference

### Client

- `client.create(template:, timeout_ms:, metadata:, envs:)` - Create a new sandbox
- `client.connect(sandbox_id, timeout_ms:)` - Connect to existing sandbox
- `client.get(sandbox_id)` - Get sandbox details
- `client.list(metadata:, state:)` - List all sandboxes
- `client.kill(sandbox_id)` - Kill a sandbox

### Sandbox

- `sandbox.commands.run(command, cwd:, envs:, timeout:)` - Run a command
- `sandbox.files.read(path)` - Read file content
- `sandbox.files.write(path, content)` - Write file content
- `sandbox.files.list(path)` - List directory
- `sandbox.set_timeout(timeout_ms)` - Extend sandbox lifetime
- `sandbox.keep_alive(duration_ms:)` - Keep sandbox alive
- `sandbox.get_host(port)` - Get public URL for port
- `sandbox.kill` - Terminate sandbox

## License

MIT
