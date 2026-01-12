#!/usr/bin/env ruby
# frozen_string_literal: true

# Basic E2B Ruby SDK usage example
#
# Run with: ruby examples/basic_usage.rb
#
# Requires E2B_API_KEY environment variable

require_relative "../lib/e2b"

# Check for API key
unless ENV["E2B_API_KEY"]
  puts "Error: E2B_API_KEY environment variable is required"
  puts "Get your API key at https://e2b.dev"
  exit 1
end

# Configure E2B
E2B.configure do |config|
  config.api_key = ENV["E2B_API_KEY"]
end

client = E2B::Client.new

puts "Creating sandbox..."
sandbox = client.create(template: "base", timeout_ms: 300_000) # 5 minutes

puts "Sandbox ID: #{sandbox.sandbox_id}"

# Run a simple command
puts "\nRunning 'echo Hello World'..."
result = sandbox.commands.run("echo 'Hello from E2B!'")
puts "Output: #{result.stdout}"
puts "Exit code: #{result.exit_code}"

# Write a file
puts "\nWriting a file..."
sandbox.filesystem.write("/home/user/test.txt", "Hello, World!")

# Read it back
content = sandbox.filesystem.read("/home/user/test.txt")
puts "File content: #{content}"

# List directory
puts "\nListing /home/user:"
files = sandbox.filesystem.list("/home/user")
files.each do |file|
  puts "  #{file[:type] == 'dir' ? '📁' : '📄'} #{file[:name]}"
end

# Run a more complex command
puts "\nInstalling Node.js package..."
result = sandbox.commands.run("npm init -y && npm install lodash", cwd: "/home/user", timeout: 60)
if result.exit_code == 0
  puts "Package installed successfully"
else
  puts "Error: #{result.stderr}"
end

# Clean up
puts "\nKilling sandbox..."
sandbox.kill
puts "Done!"
