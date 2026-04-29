# frozen_string_literal: true

require_relative "lib/e2b/version"

Gem::Specification.new do |spec|
  spec.name = "e2b"
  spec.version = E2B::VERSION
  spec.authors = ["Tao Luo"]
  spec.email = ["luotao@hey.com"]

  spec.summary = "Ruby SDK for E2B sandbox API"
  spec.description = <<~DESC
    Ruby client for creating and managing E2B sandboxes - secure cloud environments
    for AI-generated code execution. Supports sandbox lifecycle management, command
    execution, file operations, PTY terminals, git operations, and directory watching.
  DESC
  spec.homepage = "https://github.com/ya-luotao/e2b-ruby"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.0.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/ya-luotao/e2b-ruby"
  spec.metadata["documentation_uri"] = "https://e2b.dev/docs"
  spec.metadata["changelog_uri"] = "https://github.com/ya-luotao/e2b-ruby/blob/main/CHANGELOG.md"

  spec.files = Dir.glob("lib/**/*") + ["README.md", "LICENSE.txt"]
  spec.require_paths = ["lib"]

  spec.add_dependency "faraday", ">= 1.0", "< 3.0"
  spec.add_dependency "faraday-multipart", "~> 1.0"
  spec.add_dependency "base64", "~> 0.2"

  spec.add_development_dependency "rake", "~> 13.0"
  spec.add_development_dependency "rspec", "~> 3.0"
  spec.add_development_dependency "webmock", "~> 3.0"
end
