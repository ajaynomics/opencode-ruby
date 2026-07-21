# frozen_string_literal: true

require "test_helper"

class ReadmeContractTest < Minitest::Test
  README = File.read(File.expand_path("../README.md", __dir__))

  def test_server_compatibility_points_to_exact_certification_evidence
    assert_includes README, "https://github.com/ajaynomics/opencode-compat"
    assert_includes README, "manifests/image-matrix.json"
    assert_includes README, "manifests/runtime-tuples.json"
    refute_match(/OpenCode server\s*(?:>=|≥)\s*\d/, README)
  end

  def test_release_guidance_does_not_claim_trusted_publishing_is_configured
    assert_includes README, "`0.0.1.alpha8` package contained unrepaired source"
    assert_includes README, "was yanked"
    assert_includes README, "registration is not confirmed for alpha9"
    assert_includes README, "does not currently guarantee publication"
  end

  def test_compatibility_documents_every_runtime_dependency
    assert_includes README, "`activesupport (>= 6.1, < 9.0)`"
    assert_includes README, "`marcel (~> 1.0)`"
  end
end
