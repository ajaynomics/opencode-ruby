# frozen_string_literal: true

require "minitest/autorun"
require "yaml"

class ReleaseWorkflowTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  WORKFLOW_PATH = File.join(ROOT, ".github", "workflows", "release.yml")

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
    assert_equal 1, steps.count { |step| step["uses"] == "rubygems/release-gem@v1" }
    refute steps.any? { |step| step.fetch("run", "").match?(/\bgem\s+push\b/) }
  end
end
