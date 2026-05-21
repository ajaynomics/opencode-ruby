# frozen_string_literal: true

module Opencode
  # Canonical shape of a tool part in an assistant reply.
  #
  # A tool part starts `pending` and transitions through `running` to a
  # terminal `completed` or `error`. The complete representation carries
  # seven fields, all string-keyed so views read consistent keys whether
  # the part came from a live streaming event or a post-stream message
  # poll:
  #
  #   "type"     => "tool"
  #   "tool"     => "edit"
  #   "status"   => "completed"
  #   "title"    => "Edited /INDEX.md"
  #   "input"    => { ... }   # full args the agent passed, deep-stringified
  #   "metadata" => { ... }   # tool-specific output: diff, preview, stdout, etc.
  #   "output"   => "Edited successfully."
  #   "error"    => "..."     # only when status == "error", truncated to 200 chars
  #
  # The shape is produced two ways:
  #
  #   1. Opencode::Reply#apply_tool_state — live, mid-stream, merging
  #      incoming event state into an in-memory record (previous values
  #      survive when the new event omits a field).
  #
  #   2. Opencode::ResponseParser.build_tool_summary — post-stream, built
  #      fresh from a complete OpenCode message returned by
  #      /session/:id/message during recovery / final-exchange polling.
  #
  # Existence reason: the two paths used to drift. ResponseParser stripped
  # `metadata` and whitelisted `input` to a fixed key list, so `parts_json`
  # saved on finalize had strictly less data than the streaming DOM had
  # shown. The visible symptom was "I saw the diff while streaming and it
  # disappeared when the turn finished". This class is the single source of
  # truth that prevents that drift.
  module ToolPart
    MAX_ERROR_LEN = 200
    INVALID_TOOL = "invalid"

    module_function

    # Build a fresh canonical tool-part hash from one OpenCode message
    # part (the shape that arrives through /session/:id/message).
    # Used by ResponseParser for recovery and final-exchange polling.
    def from_message_part(part)
      state = state_of(part)
      build_canonical(
        tool: part[:tool] || part["tool"],
        status: state_value(state, :status),
        title: state_value(state, :title),
        input: state_value(state, :input),
        metadata: state_value(state, :metadata),
        output: state_value(state, :output),
        error: state_value(state, :error)
      )
    end

    # Merge an incoming `message.part.updated` event state into an
    # existing record. Used by Reply#apply_tool_state during streaming.
    #
    # Fields the event omits (or that arrive empty) leave the record's
    # previous value intact. Mid-tool events are partial by design.
    #
    # In addition to the canonical render fields (status, title, input,
    # metadata, output, error), this also persists `callID` and
    # `messageID` from the incoming state. Those identifiers are needed
    # by downstream lookups (e.g. matching an ask-user reply event back
    # to the originating tool part by callID) and would otherwise be
    # silently dropped on the way into Reply.parts JSON.
    #
    # Returns the (mutated) record for chaining.
    def merge_streaming_state(record, part)
      state = state_of(part)

      tool = part[:tool] || part["tool"]
      # Preserve original tool name if OpenCode later renames to "invalid"
      # mid-session — we want to keep rendering the original name.
      record["tool"] = tool if tool.present? && tool != INVALID_TOOL

      status = state_value(state, :status)
      record["status"] = status if status

      title = state_value(state, :title)
      record["title"] = title if title.present?

      input = state_value(state, :input)
      record["input"] = stringify_deep(input) if input.present?

      metadata = state_value(state, :metadata)
      record["metadata"] = stringify_deep(metadata) if metadata.present?

      output = state_value(state, :output)
      record["output"] = output if output.present?

      error = state_value(state, :error)
      record["error"] = error.to_s.truncate(MAX_ERROR_LEN) if error.present?

      # callID and messageID moved from state.* to the part's top level
      # somewhere in opencode v1.15.x. Read top-level first, fall back
      # to state.* for any older versions that may still be in flight.
      # Without this, merge_pending_question_into_existing_tool_part
      # (which searches @parts by callID) silently no-ops, and the
      # question form renders with no questions or routing IDs.
      call_id = part[:callID] || part["callID"] || state_value(state, :callID)
      record["callID"] = call_id if call_id.present?

      message_id = part[:messageID] || part["messageID"] || state_value(state, :messageID)
      record["messageID"] = message_id if message_id.present?

      record
    end

    class << self
      private

      def state_of(part)
        part[:state] || part["state"] || {}
      end

      def state_value(state, key)
        return nil unless state.is_a?(Hash)
        state[key] || state[key.to_s]
      end

      def build_canonical(tool:, status:, title:, input:, metadata:, output:, error:)
        hash = {
          "type" => "tool",
          "tool" => tool.to_s.presence,
          "status" => status,
          "title" => title.presence,
          "input" => stringify_deep(input).presence,
          "metadata" => stringify_deep(metadata).presence,
          "output" => output.presence
        }
        hash["error"] = error.to_s.truncate(MAX_ERROR_LEN).presence if status == "error"
        hash.compact
      end

      def stringify_deep(value)
        case value
        when Hash
          value.each_with_object({}) { |(k, v), h| h[k.to_s] = stringify_deep(v) }
        when Array
          value.map { |v| stringify_deep(v) }
        else
          value
        end
      end
    end
  end
end
