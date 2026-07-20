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
    assert_equal 1, steps.count { |step| step["uses"] == RELEASE_GEM_ACTION }
    assert steps.filter_map { |step| step["uses"] }.all? { |uses| uses.match?(/@[0-9a-f]{40}\z/) }
    refute steps.any? { |step| step.fetch("run", "").match?(/\bgem\s+push\b/) }
  end

  def test_release_tag_must_match_the_gem_version_before_publish
    steps = push_job.fetch("steps")
    preflight_index = steps.index { |step| step["name"] == "Verify tag matches gem version" }
    publish_index = steps.index { |step| step["uses"] == RELEASE_GEM_ACTION }

    refute_nil preflight_index
    refute_nil publish_index
    assert_operator preflight_index, :<, publish_index

    preflight = steps.fetch(preflight_index)
    assert_equal "${{ github.ref_name }}", preflight.dig("env", "RELEASE_TAG")
    assert_includes preflight.fetch("run"), "unless Opencode::VERSION == expected"
  end
end
