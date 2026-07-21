# frozen_string_literal: true

require "minitest/autorun"
require "yaml"

class ReleaseWorkflowTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  WORKFLOW_PATH = File.join(ROOT, ".github", "workflows", "release.yml")
  SETUP_RUBY_ACTION = "ruby/setup-ruby@003a5c4d8d6321bd302e38f6f0ec593f77f06600"
  RELEASE_GEM_ACTION = "rubygems/release-gem@052cc82692552de3ef2b81fd670e41d13cba8092"

  def workflow
    @workflow ||= YAML.safe_load(File.read(WORKFLOW_PATH), aliases: false)
  end

  def push_job
    workflow.fetch("jobs").fetch("push")
  end

  def verify_job
    workflow.fetch("jobs").fetch("verify")
  end

  def test_release_job_is_inert_on_non_github_runners
    assert_equal "${{ github.server_url == 'https://github.com' }}", push_job.fetch("if")
  end

  def test_release_job_keeps_the_trusted_publisher_boundary
    assert_equal "release", push_job.fetch("environment")
    assert_equal(
      { "contents" => "write", "id-token" => "write" },
      push_job.fetch("permissions")
    )

    steps = push_job.fetch("steps")
    setup_ruby = steps.find { |step| step["uses"] == SETUP_RUBY_ACTION }

    assert_equal "4.0", setup_ruby.dig("with", "ruby-version")
    assert_equal true, setup_ruby.dig("with", "bundler-cache")
    assert_equal 1, steps.count { |step| step["uses"] == RELEASE_GEM_ACTION }
    assert steps.filter_map { |step| step["uses"] }.all? { |uses| uses.match?(/@[0-9a-f]{40}\z/) }
    refute steps.any? { |step| step.key?("run") }
  end

  def test_release_tag_must_match_the_gem_version_before_publish
    preflight = verify_job.fetch("steps").find { |step| step["name"] == "Verify tag matches gem version" }

    refute_nil preflight
    assert_equal "${{ github.ref_name }}", preflight.dig("env", "RELEASE_TAG")
    assert_includes preflight.fetch("run"), "unless Opencode::VERSION == expected"
  end

  def test_verification_job_has_read_only_credentials
    assert_equal({ "contents" => "read" }, verify_job.fetch("permissions"))

    checkout = verify_job.fetch("steps").find { |step| step.fetch("uses", "").start_with?("actions/checkout@") }
    assert_equal false, checkout.dig("with", "persist-credentials")
  end

  def test_release_verifies_the_supported_matrix_and_installed_gem_before_publish
    assert_equal %w[3.2 3.3 3.4 4.0], verify_job.dig("strategy", "matrix", "ruby")
    assert_equal "verify", push_job.fetch("needs")

    commands = verify_job.fetch("steps").filter_map { |step| step["run"] }.join("\n")
    assert_includes commands, "bundle exec rake test"
    assert_includes commands, "gem build opencode-ruby.gemspec"
    assert_includes commands, "bundle exec ruby -e"
    assert_includes commands, 'GEM_HOME="${RUNNER_TEMP}/opencode-ruby-${{ matrix.ruby }}"'
    assert_includes commands, 'gem_file="opencode-ruby-$(ruby -Ilib -ropencode/version'
    assert_includes commands, 'gem install --local "$gem_file" --no-document'
    assert_includes commands, "Gem.loaded_specs.fetch(\"opencode-ruby\").full_gem_path"
    assert_includes commands, "ruby -ropencode-ruby"
  end
end
