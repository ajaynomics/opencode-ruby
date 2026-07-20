# frozen_string_literal: true

require_relative "lib/opencode/version"

Gem::Specification.new do |spec|
  spec.name          = "opencode-ruby"
  spec.version       = Opencode::VERSION
  spec.authors       = ["Ajay Krishnan"]
  spec.email         = ["opencode-ruby@ajay.to"]

  spec.summary       = "Idiomatic Ruby client for OpenCode (HTTP + SSE)."
  spec.description   = <<~DESC
    Hand-rolled, opinionated Ruby SDK for OpenCode's REST + SSE API.
    Block-form streaming, value-object responses, automatic SSE
    reconnection. Complement to opencode_client (auto-generated from
    OpenAPI) — pick this one if you want a small Ruby-idiomatic surface;
    pick opencode_client if you want every endpoint with generated types.
  DESC
  spec.homepage      = "https://github.com/ajaynomics/opencode-ruby"
  spec.license       = "MIT"
  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata["homepage_uri"]    = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"]   = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["bug_tracker_uri"] = "#{spec.homepage}/issues"

  spec.files = Dir.glob("lib/**/*.rb") +
               Dir.glob("examples/**/*.rb") +
               %w[README.md LICENSE CHANGELOG.md opencode-ruby.gemspec]
  spec.require_paths = ["lib"]

  # ActiveSupport supplies the small set of core extensions used by the
  # client without pulling in Rails. Marcel identifies artifact content types.
  spec.add_runtime_dependency "activesupport", ">= 6.1", "< 9.0"
  spec.add_runtime_dependency "marcel", "~> 1.0"

  spec.add_development_dependency "minitest", "~> 5.20"
  spec.add_development_dependency "rake", "~> 13.0"
  spec.add_development_dependency "webmock", "~> 3.20"
end
