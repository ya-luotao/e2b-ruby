#!/usr/bin/env ruby
# frozen_string_literal: true

# Example: Running Claude Code CLI in an E2B sandbox
#
# This example shows how to:
# - Create a sandbox with Claude Code CLI installed
# - Execute Claude Code with streaming output
# - Parse the JSON stream output
#
# Run with: ruby examples/claude_code_runner.rb
#
# Requires:
#   E2B_API_KEY - E2B API key
#   ANTHROPIC_API_KEY or CLAUDE_CODE_OAUTH_TOKEN - Claude authentication

require_relative "../lib/e2b"
require "json"

# Check for required environment variables
unless ENV["E2B_API_KEY"]
  puts "Error: E2B_API_KEY environment variable is required"
  exit 1
end

unless ENV["ANTHROPIC_API_KEY"] || ENV["CLAUDE_CODE_OAUTH_TOKEN"]
  puts "Error: ANTHROPIC_API_KEY or CLAUDE_CODE_OAUTH_TOKEN is required"
  exit 1
end

# Configure E2B
E2B.configure do |config|
  config.api_key = ENV["E2B_API_KEY"]
end

client = E2B::Client.new

puts "Creating sandbox..."
sandbox = client.create(template: "base", timeout_ms: 600_000) # 10 minutes

puts "Sandbox ID: #{sandbox.sandbox_id}"

# Install Claude Code CLI
puts "\nInstalling Claude Code CLI..."
result = sandbox.commands.run(
  "npm install -g @anthropic-ai/claude-code",
  timeout: 180
)

if result.exit_code != 0
  puts "Error installing Claude Code: #{result.stderr}"
  sandbox.kill
  exit 1
end

puts "Claude Code CLI installed"

# Set up environment variables for Claude
env_vars = {}
env_vars["ANTHROPIC_API_KEY"] = ENV["ANTHROPIC_API_KEY"] if ENV["ANTHROPIC_API_KEY"]
env_vars["CLAUDE_CODE_OAUTH_TOKEN"] = ENV["CLAUDE_CODE_OAUTH_TOKEN"] if ENV["CLAUDE_CODE_OAUTH_TOKEN"]

# Create a project directory
sandbox.commands.run("mkdir -p /home/user/project")

# Run Claude Code with a simple prompt
prompt = "Create a simple hello.py file that prints 'Hello from Claude!'"

puts "\nRunning Claude Code with prompt: #{prompt}"
puts "-" * 50

# Build the command
claude_cmd = [
  "claude",
  "-p",
  "--output-format", "stream-json",
  "--permission-mode", "acceptEdits",
  "\"#{prompt.gsub('"', '\\"')}\""
].join(" ")

# Execute Claude Code
# Note: In production, you'd want to stream this output
result = sandbox.commands.run(
  claude_cmd,
  cwd: "/home/user/project",
  envs: env_vars,
  timeout: 120
)

# Parse the streaming JSON output
puts "\nClaude Output:"
result.stdout.each_line do |line|
  next if line.strip.empty?

  begin
    event = JSON.parse(line)
    case event["type"]
    when "assistant"
      # Extract text content
      if event.dig("message", "content")
        event["message"]["content"].each do |block|
          if block["type"] == "text"
            print block["text"]
          elsif block["type"] == "tool_use"
            puts "\n[Using tool: #{block['name']}]"
          end
        end
      end
    when "content_block_delta"
      if event.dig("delta", "text")
        print event["delta"]["text"]
      end
    when "result"
      puts "\n\n[Session ID: #{event['session_id']}]"
      if event["usage"]
        puts "[Tokens: #{event['usage']['input_tokens']} in, #{event['usage']['output_tokens']} out]"
      end
    end
  rescue JSON::ParserError
    # Skip non-JSON lines
  end
end

puts "\n" + "-" * 50

# Check what Claude created
puts "\nFiles in project directory:"
files = sandbox.filesystem.list("/home/user/project")
files.each do |file|
  puts "  #{file[:name]}"
end

# Read the created file if it exists
if files.any? { |f| f[:name] == "hello.py" }
  puts "\nContents of hello.py:"
  content = sandbox.filesystem.read("/home/user/project/hello.py")
  puts content

  puts "\nRunning hello.py:"
  run_result = sandbox.commands.run("python3 hello.py", cwd: "/home/user/project")
  puts run_result.stdout
end

# Clean up
puts "\nKilling sandbox..."
sandbox.kill
puts "Done!"
