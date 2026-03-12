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

# Option 1: Use Sandbox class directly (recommended, matches official SDK)
puts "Creating sandbox..."
sandbox = E2B::Sandbox.create(template: "base", timeout: 300)

puts "Sandbox ID: #{sandbox.sandbox_id}"

# Run a simple command
puts "\nRunning 'echo Hello World'..."
result = sandbox.commands.run("echo 'Hello from E2B!'")
puts "Output: #{result.stdout}"
puts "Exit code: #{result.exit_code}"

# Write a file
puts "\nWriting a file..."
sandbox.files.write("/home/user/test.txt", "Hello, World!")

# Read it back
content = sandbox.files.read("/home/user/test.txt")
puts "File content: #{content}"

# List directory
puts "\nListing /home/user:"
entries = sandbox.files.list("/home/user")
entries.each do |entry|
  type_icon = entry.directory? ? "D" : "F"
  puts "  [#{type_icon}] #{entry.name} (#{entry.size} bytes)"
end

# Run a command with streaming output
puts "\nRunning with streaming..."
sandbox.commands.run("for i in 1 2 3; do echo \"Count: $i\"; sleep 0.5; done",
  on_stdout: ->(data) { print "  > #{data}" })

# Background command
puts "\nStarting background process..."
handle = sandbox.commands.run("sleep 5 && echo done", background: true)
puts "Background PID: #{handle.pid}"
handle.kill
puts "Background process killed"

# Git operations
puts "\nInitializing git repo..."
sandbox.git.init("/home/user/project")
sandbox.git.configure_user("Test User", "test@example.com", path: "/home/user/project")

# File info
puts "\nFile info:"
info = sandbox.files.get_info("/home/user/test.txt")
puts "  Path: #{info.path}, Size: #{info.size}, Type: #{info.type}"

# Clean up
puts "\nKilling sandbox..."
sandbox.kill
puts "Done!"
