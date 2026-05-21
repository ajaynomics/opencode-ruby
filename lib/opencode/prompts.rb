# frozen_string_literal: true

module Opencode
  # Per-Reply registry of interactive prompts (questions + permissions)
  # opencode has asked the user but not yet resolved. Lives on
  # Opencode::Reply for the lifetime of one streaming turn.
  #
  # Two access patterns:
  #
  #   * by request id ("que_..." or "per_...") — for the controller
  #     posting a user's answer back.
  #   * by {message_id, call_id} — for the order-race fix where
  #     `question.asked` may arrive before the matching tool part.
  #
  # The registry also exposes a `prompt_blocked?` predicate that
  # Opencode::Client uses to suspend the SSE deadline check while
  # a healthy wait is in progress.
  class Prompts
    Entry = Struct.new(:kind, :request, :asked_at, keyword_init: true)

    def initialize
      @entries = {}
      @by_call = {}
    end

    def record_question(request)
      record(:question, request)
    end

    def record_permission(request)
      record(:permission, request)
    end

    # Returns the raw request hash (not the Entry wrapper) so callers
    # don't depend on internal bookkeeping shape.
    def find(request_id)
      @entries[request_id]&.request
    end

    # Returns the raw request hash, same shape as #find.
    def find_by_call(message_id:, call_id:)
      key = call_key(message_id, call_id)
      @by_call[key]&.request
    end

    def resolve(request_id)
      entry = @entries.delete(request_id)
      return unless entry

      tool = entry.request[:tool]
      return unless tool

      @by_call.delete(call_key(tool[:messageID], tool[:callID]))
    end

    def each_pending
      @entries.each_value { |entry| yield(entry.kind, entry.request) }
    end

    def any_pending?
      @entries.any?
    end
    alias_method :prompt_blocked?, :any_pending?

    def asked_at(request_id)
      @entries[request_id]&.asked_at
    end

    private

    def record(kind, request)
      entry = Entry.new(
        kind: kind,
        request: request,
        asked_at: Process.clock_gettime(Process::CLOCK_MONOTONIC)
      )
      @entries[request[:id]] = entry

      tool = request[:tool]
      @by_call[call_key(tool[:messageID], tool[:callID])] = entry if tool
    end

    def call_key(message_id, call_id)
      [ message_id, call_id ].join(":")
    end
  end
end
