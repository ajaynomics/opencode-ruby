# frozen_string_literal: true

require "test_helper"

class ConversationRecipeTest < Minitest::Test
  RECIPE = File.read(File.expand_path("../examples/conversation_recipe.rb", __dir__))

  def test_recovery_retries_with_the_recreated_session
    assert_includes RECIPE,
      "session_id = message.conversation.recreate_opencode_session!(client)"
  end

  def test_user_facing_error_does_not_include_exception_details
    assert_includes RECIPE, 'content: "An error occurred. Please try again."'
    refute_includes RECIPE, 'content: "An error occurred: #{e.message.truncate(200)}"'
  end

  def test_error_reporting_works_on_the_supported_rails_6_1_baseline
    assert_includes RECIPE, "Rails.logger.error(e.full_message)"
    refute_includes RECIPE, "Rails.error.report"
  end
end
