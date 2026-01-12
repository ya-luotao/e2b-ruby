# frozen_string_literal: true

require "bundler/gem_tasks"
require "rspec/core/rake_task"

RSpec::Core::RakeTask.new(:spec)

task default: :spec

desc "Run examples (requires E2B_API_KEY)"
task :examples do
  Dir["examples/*.rb"].each do |example|
    puts "\n" + "=" * 60
    puts "Running: #{example}"
    puts "=" * 60
    system("ruby #{example}")
  end
end

desc "Start an interactive console with E2B loaded"
task :console do
  require "irb"
  require_relative "lib/e2b"

  if ENV["E2B_API_KEY"]
    E2B.configure do |config|
      config.api_key = ENV["E2B_API_KEY"]
    end
    puts "E2B configured with API key"
  else
    puts "Warning: E2B_API_KEY not set"
  end

  ARGV.clear
  IRB.start
end
