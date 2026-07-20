# frozen_string_literal: true

require "minitest/autorun"
require "yaml"

class WorkflowContractTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  WORKFLOW_DIRECTORY = File.join(ROOT, ".github", "workflows")
  TEST_WORKFLOW_PATH = File.join(WORKFLOW_DIRECTORY, "test.yml")
  ACTION_PINS = {
    "actions/checkout" => "93cb6efe18208431cddfb8368fd83d5badbf9bfd",
    "ruby/setup-ruby" => "003a5c4d8d6321bd302e38f6f0ec593f77f06600",
    "rubygems/release-gem" => "052cc82692552de3ef2b81fd670e41d13cba8092"
  }.freeze

  def test_matrix_covers_every_supported_ruby
    workflow = YAML.safe_load(File.read(TEST_WORKFLOW_PATH), aliases: false)
    versions = workflow.dig("jobs", "test", "strategy", "matrix", "ruby")

    assert_equal %w[3.2 3.3 3.4 4.0], versions
  end

  def test_every_third_party_action_uses_its_reviewed_commit
    action_uses = Dir[File.join(WORKFLOW_DIRECTORY, "*.{yml,yaml}")].sort.flat_map do |path|
      workflow = YAML.safe_load(File.read(path), aliases: false)

      workflow_uses(workflow)
    end

    assert_equal 5, action_uses.length
    action_uses.each do |action_use|
      action, separator, revision = action_use.rpartition("@")

      assert_equal "@", separator
      assert_equal ACTION_PINS.fetch(action), revision
      assert_match(/\A[0-9a-f]{40}\z/, revision)
    end
  end

  def test_action_discovery_only_reads_workflow_action_locations
    workflow = YAML.safe_load(<<~YAML, aliases: false)
      jobs:
        reusable:
          uses: "owner/workflow@revision"
          with:
            uses: ordinary-job-input
        test:
          steps:
            - uses: "owner/action@revision"
              with:
                uses: ordinary-step-input
    YAML

    assert_equal %w[owner/workflow@revision owner/action@revision], workflow_uses(workflow)
  end

  private

  def workflow_uses(node)
    node.fetch("jobs").values.flat_map do |job|
      action_uses = job.key?("uses") ? [job.fetch("uses")] : []
      step_uses = job.fetch("steps", []).filter_map { |step| step["uses"] }

      action_uses.concat(step_uses)
    end
  end
end
