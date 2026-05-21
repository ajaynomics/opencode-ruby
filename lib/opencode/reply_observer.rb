# frozen_string_literal: true

module Opencode
  # The canonical observer protocol for Opencode::Reply — every event
  # Reply dispatches, documented in one place, with safe no-op defaults.
  #
  # Include this module in a reply-stream class to get two things:
  #
  # 1. **Compile-time checklist.** Override only the callbacks you care
  #    about; the rest inherit a no-op. Forgetting to handle a new event
  #    never crashes the stream.
  # 2. **Protocol documentation that can't rot.** The signatures here are
  #    the contract. If Reply's dispatch shape ever drifts, every observer
  #    using this module updates in lockstep.
  #
  # Callbacks are duck-typed in Reply — features may choose not to
  # include this module and implement the methods directly, but then
  # they lose the two benefits above.
  #
  # Every callback takes keyword arguments, so adding a new keyword later
  # only requires existing observers to add `**_` if they want to opt out
  # of breakage.
  module ReplyObserver
    # A new part was appended to the reply's parts list.
    def part_added(part:, index:)
    end

    # An existing part's content grew by a delta (streaming text or
    # reasoning).
    def part_changed(part:, index:, delta:)
    end

    # An existing part's content was rewritten to the authoritative
    # value from part.updated. Fires unconditionally when a part closes
    # so throttled observers can flush, regardless of whether content
    # actually diverged from what deltas accumulated.
    def part_finalized(part:, index:)
    end

    # A tool part transitioned status (pending → running → completed/error),
    # or its state payload (title/input/error) changed.
    def tool_progressed(part:, index:, status:, raw:)
    end

    # A step boundary with usage info. `tokens` is the raw tokens hash
    # from the step-finish part (keys: :input, :output, :reasoning, :cache).
    def step_finished(cost:, tokens:)
    end

    # The upstream session is retrying an LLM call (e.g., provider
    # rate-limit backoff). Attempt is nullable; message is a short
    # reason string.
    def session_retried(attempt:, message:)
    end

    # A session-level error surfaced. Text is a human-readable summary
    # ("ErrorName: details"); raw is the full error hash.
    def session_errored(text:, raw:)
    end

    # The authoritative message.info was updated (cost, tokens, provider
    # error metadata). Fires late in the stream after the agent closes.
    def message_updated(info:)
    end

    # Agent's internal todo list changed. Todos are whatever shape the
    # agent's task tool uses.
    def todos_changed(todos:)
    end

    # opencode emitted a question.asked event — the agent's `question`
    # tool is suspended waiting for the user's reply. `request` is the
    # full QuestionRequest hash ({id, sessionID, questions, tool?}).
    def question_asked(request:, raw:)
    end

    # opencode emitted a question.replied event — the user submitted
    # answers (Array<Array<String>>, one inner array per question).
    # `asked_at` is the monotonic clock value when question.asked was
    # observed, for latency telemetry; nil if asked never arrived.
    def question_replied(request_id:, answers:, raw:, asked_at:)
    end

    # opencode emitted a question.rejected event — the user dismissed
    # the prompt, or it was cancelled (e.g., container shutdown).
    def question_rejected(request_id:, raw:, asked_at:)
    end

    # opencode emitted a permission.asked event — a tool is requesting
    # user permission to proceed. `request` is the PermissionRequest
    # hash ({id, sessionID, permission, patterns, metadata, always, tool?}).
    def permission_asked(request:, raw:)
    end

    # opencode emitted a permission.replied event — the user chose
    # once/always/reject. `reply` is the string. `asked_at` per
    # question_replied semantics.
    def permission_replied(request_id:, reply:, raw:, asked_at:)
    end
  end
end
