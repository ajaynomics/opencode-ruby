# frozen_string_literal: true

# Rails integration recipe — copy + adapt.
#
# This is NOT part of opencode-ruby. It's the canonical pattern showing
# how to wire the gem's primitives into a Rails ActiveRecord app. Drop
# this file into your `app/models/` (rename it), adapt the schema, and
# you have a working block-streaming chat with row-locked session
# lifecycle and CAS-safe finalize.
#
# What this recipe demonstrates:
#
#   1. Schema (below in a comment) — the migration you'll need
#   2. Session lifecycle — idempotent ensure! with with_lock
#   3. Mid-stream parts persistence via update_columns (bypasses
#      AR callbacks so Turbo broadcasts don't fire per-part)
#   4. CAS-safe finalize — concurrent cancel wins
#   5. Recovery from SessionNotFoundError — recreate once + retry
#
# If you want this as a one-liner (`acts_as_opencode_session`), open
# an issue on the repo. The gem ships this recipe instead of a concern
# because the right shape depends on the host app's conventions — and
# shipping a half-built concern is worse than shipping a clear
# blueprint you can adapt.
#
# Suggested schema (adapt naming to your domain):
#
#   create_table :conversations do |t|
#     t.references :user, null: false, foreign_key: true
#     t.string :title
#     t.string :opencode_session_id
#     t.timestamps
#     t.index :opencode_session_id, unique: true,
#             where: "opencode_session_id IS NOT NULL"   # partial unique
#   end
#
#   create_table :messages do |t|
#     t.references :conversation, null: false, foreign_key: true
#     t.string  :role,    null: false           # "user" or "assistant"
#     t.integer :status,  null: false, default: 0   # see enum below
#     t.text    :content, null: false, default: ""
#     t.json    :parts_json,      null: false, default: []
#     t.json    :tool_calls_json, null: false, default: []
#     t.decimal :cost, precision: 10, scale: 6
#     t.integer :input_tokens
#     t.integer :output_tokens
#     t.timestamps
#   end

class Conversation < ApplicationRecord
  belongs_to :user
  has_many :messages, dependent: :destroy

  # Returns the OpenCode session id for this conversation, creating one
  # if needed. Idempotent. Race-safe via row-lock + double-check.
  def ensure_opencode_session!(client)
    return opencode_session_id if opencode_session_id.present?

    with_lock do
      return opencode_session_id if opencode_session_id.present?
      session = client.create_session(title: title)
      update!(opencode_session_id: session[:id] || session["id"])
    end
    opencode_session_id
  rescue ActiveRecord::RecordNotUnique
    # Another worker raced past the partial unique index. Loser reloads.
    reload
    opencode_session_id
  end

  # Replace a stale upstream session. Used by SessionNotFoundError
  # recovery in the streaming job below.
  def recreate_opencode_session!(client)
    pre_id = opencode_session_id
    with_lock do
      return opencode_session_id if opencode_session_id.present? && opencode_session_id != pre_id
      session = client.create_session(title: title)
      update!(opencode_session_id: session[:id] || session["id"])
    end
    opencode_session_id
  end
end

class Message < ApplicationRecord
  belongs_to :conversation

  enum status: { pending: 0, streaming: 1, completed: 2, cancelled: 3, errored: 4 }
end

# The streaming job. Compose Opencode::Client + ActiveRecord; that's it.
class GenerateAssistantReplyJob < ApplicationJob
  def perform(message_id, user_prompt)
    message = Message.find(message_id)
    return unless message.pending?

    client = Opencode::Client.new(
      base_url: ENV.fetch("OPENCODE_BASE_URL"),
      password: ENV["OPENCODE_SERVER_PASSWORD"]
    )

    session_id = message.conversation.ensure_opencode_session!(client)
    message.update!(status: :streaming)

    attempted_recreate = false
    begin
      reply = client.stream(session_id, user_prompt) do |part|
        # Mid-stream snapshot: update_columns bypasses AR callbacks so
        # an after_update_commit broadcasts_refreshes_to(conversation)
        # doesn't fire per-part and clobber per-part Turbo broadcasts
        # you might be doing separately. The final write below uses
        # update! to fire callbacks deliberately.
        message.update_columns(
          parts_json: reply_parts_so_far(part, message),
          updated_at: Time.current
        )
      end

      # CAS-safe finalize: only land the final state if no concurrent
      # cancel got there first.
      message.with_lock do
        return unless message.reload.pending? || message.streaming?
        message.update!(
          status: :completed,
          content: reply.full_text,
          parts_json: reply.parts_json,
          tool_calls_json: reply.tool_parts
        )
      end
    rescue Opencode::SessionNotFoundError, Opencode::StaleSessionError
      raise if attempted_recreate
      session_id = message.conversation.recreate_opencode_session!(client)
      attempted_recreate = true
      retry
    end
  rescue StandardError => e
    Rails.logger.error(e.full_message)
    message&.update!(status: :errored, content: "An error occurred. Please try again.")
  end

  private

  # Builds the parts array up to (and including) the current part by
  # poking the gem's internal Reply state. In practice you'd capture
  # the Reply instance from the block via a closure, OR derive from
  # `part` if you only need the latest part.
  def reply_parts_so_far(part, message)
    parts = (message.parts_json || []).dup
    # Trivial dedup: replace or append by part id, if your wire-format
    # includes one. For real merge logic, lift Opencode::Reply's
    # part_index_by_id / append_part pattern.
    parts << part unless parts.any? { |existing| existing["id"] == part["id"] }
    parts
  end
end
