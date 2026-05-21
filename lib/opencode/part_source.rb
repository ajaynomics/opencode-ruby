# frozen_string_literal: true

require "set"

module Opencode
  # A Part's provenance — where it came from in the OpenCode wire model.
  #
  # Two source classes exist:
  #
  #   - Wire parts: emitted by the OpenCode message-parts pipeline and
  #     echoed back by `GET /session/:id/message`. These are authoritative
  #     for finalization — when the final exchange poll lands, wire parts
  #     overwrite whatever streaming captured.
  #
  #   - Stream-only parts: synthesized from bus events that OpenCode does
  #     NOT persist as message parts. The host's Opencode::Reply
  #     materializes them so per-product ReplyStream observers can render
  #     them through the same tool partials as real tool parts, and
  #     Opencode::Turn preserves them across exchange-finalization so the
  #     final assistant message keeps what the user watched live.
  #
  # `todo.updated` is the first stream-only source (OpenCode emits the
  # full todo list on a bus event but never records it as a message part).
  # Future sources land here too: add the constant, add it to STREAM_ONLY,
  # both `Reply#append_part` callers and `Turn#stream_only_part?` keep
  # working with no further edits.
  #
  # This module exists because the previous shape coupled Reply and Turn
  # through a magic-string comparison of `metadata.source ==
  # Opencode::Reply::TODO_STREAM_SOURCE`. Two classes carrying the same
  # discriminator string is a "next time someone adds a source they'll
  # only update one place" bug waiting to happen. The source-of-truth
  # now lives here; both consumers go through `stream_only?(part)`.
  module PartSource
    TODO_UPDATED = "todo.updated"
    STREAM_ONLY = Set[TODO_UPDATED].freeze

    module_function

    # True iff the part's metadata.source is one of the stream-only
    # sources. Tolerates non-Hash input (returns false) so callers don't
    # have to guard before asking.
    def stream_only?(part)
      return false unless part.is_a?(Hash)

      STREAM_ONLY.include?(part.dig("metadata", "source"))
    end

    # Stamps `source:` into part_hash's metadata. Raises ArgumentError on
    # an unknown source so typos surface at write time, not at the next
    # `stream_only?` check (which would silently return false).
    # Mutates and returns the input hash for chaining.
    def stamp(part_hash, source:)
      raise ArgumentError, "unknown stream-only source #{source.inspect}; " \
        "register it in Opencode::PartSource::STREAM_ONLY first" unless STREAM_ONLY.include?(source)

      part_hash["metadata"] ||= {}
      part_hash["metadata"]["source"] = source
      part_hash
    end
  end
end
