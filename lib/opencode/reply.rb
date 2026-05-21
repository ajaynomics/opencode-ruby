# frozen_string_literal: true

module Opencode
  # An assistant's reply as it is being composed, live, from OpenCode SSE
  # events. A Reply accumulates parts (text, reasoning, tool invocations)
  # in the order the agent emits them and notifies observers of domain
  # transitions — parts appearing, parts growing, tools advancing,
  # sessions erroring.
  #
  # Responsibilities
  # ----------------
  #
  # * Translate raw OpenCode SSE events into domain callbacks.
  # * Own the canonical state of an in-flight reply (parts list, indices,
  #   first-token seen, message info).
  # * Apply the tail-drop safety net: when part.updated carries
  #   authoritative :text that differs from what deltas accumulated
  #   (z.ai GLM-5.1 drops trailing deltas), rewrite the part's content.
  # * Preserve the original tool name when OpenCode later renames a tool
  #   to "invalid" mid-stream.
  #
  # Not responsibilities
  # --------------------
  #
  # * Rendering HTML or broadcasting Turbo Streams (observer concern).
  # * Persisting parts to a database (observer concern).
  # * Fetching the event stream (Opencode::Client).
  # * Retry / session recovery (job concern).
  #
  # Event contract
  # --------------
  #
  # Events match OpenCode's bus schema (packages/opencode/src/session/
  # message-v2.ts, status.ts, todo.ts):
  #
  #   message.part.delta    { properties: { partID, field, delta, ... } }
  #   message.part.updated  { properties: { part: { id, type, ... } } }
  #   message.updated       { properties: { info: { tokens, cost, ... } } }
  #   session.status        { properties: { status: { type, ... } } }
  #   session.error         { properties: { error: { name, data, ... } } }
  #   todo.updated          { properties: { todos: [...] } }
  #
  # Observer callbacks
  # ------------------
  #
  # See Opencode::ReplyObserver for the full callback surface. Observers
  # are duck-typed — only the callbacks they define are invoked.
  #
  # Example
  # -------
  #
  #   reply = Opencode::Reply.new
  #   reply.add_observer(MyApp::ReplyStream.new(message:))   # your observer
  #   client.stream_events(session_id: id) { |event| reply.apply(event) }
  #   reply.result
  #   # => Opencode::Reply::Result with parts_json, full_text, reasoning_text, tool_parts
  #
  class Reply
    STREAMABLE_TYPES = %w[text reasoning tool].freeze
    TERMINAL_TOOL_STATUSES = %w[completed error].freeze
    TODO_TOOLS = %w[todowrite todoread].freeze

    # The denormalized output of a Reply once streaming completes (or
    # recovery via Reply.distill produces an equivalent shape). Symmetric
    # with Opencode::Turn::Result. Accessible by both message-style
    # (`result.full_text`) and hash-style (`result[:full_text]`) syntax
    # — Struct supports both natively — but the typed shape stops
    # callers from poking arbitrary keys.
    Result = Struct.new(:parts_json, :full_text, :reasoning_text, :tool_parts, keyword_init: true)

    attr_reader :parts, :info, :total_cost, :total_input_tokens, :total_output_tokens, :prompts

    def initialize
      @parts = []
      @part_index_by_id = {}
      @part_type_by_id = {}
      @observers = []
      @first_text_seen = false
      @info = nil
      @total_cost = 0.0
      @total_input_tokens = 0
      @total_output_tokens = 0
      @todo_part_index = nil
      @prompts = Opencode::Prompts.new
      # Keyed by [message_id, call_id]: question.asked payloads that
      # arrived before their matching tool part. Drained when the tool
      # part shows up in apply_tool_state.
      @pending_question_payloads = {}
    end

    # True while any interactive prompt (question or permission) is
    # awaiting a user reply. Opencode::Client uses this to suspend the
    # SSE inactivity deadline — a wait on the human is healthy, not a
    # hang.
    def prompt_blocked?
      @prompts.prompt_blocked?
    end

    def add_observer(observer)
      @observers << observer
      self
    end

    # Drive the state machine forward with one SSE event. Unknown event
    # types are ignored — OpenCode may add new events, and we shouldn't
    # crash on them.
    def apply(event)
      case event[:type]
      when "message.part.delta"   then apply_part_delta(event)
      when "message.part.updated" then apply_part_updated(event)
      when "message.updated"      then apply_message_updated(event)
      when "session.status"       then apply_session_status(event)
      when "session.error"        then apply_session_error(event)
      when "todo.updated"         then apply_todo_updated(event)
      when "question.asked"       then apply_question_asked(event)
      when "question.replied"     then apply_question_replied(event)
      when "question.rejected"    then apply_question_rejected(event)
      when "permission.asked"     then apply_permission_asked(event)
      when "permission.replied"   then apply_permission_replied(event)
      end
    end

    # Treat `recovered_parts` as a clean-slate baseline: replace parts,
    # clear the id→index map (recovered parts have no OpenCode part IDs),
    # and reset the running cost/token totals plus the first-text flag.
    #
    # Why reset totals: step-finish events that produced the pre-crash
    # totals are not in the recovery payload; keeping them would
    # double-count when post-recovery step-finish events accumulate
    # against the same counters.
    #
    # Used only by the recovery path — during normal streaming, parts
    # accrete via apply_* helpers and totals flow through step-finish.
    def replace_parts(recovered_parts)
      @parts = recovered_parts
      @part_index_by_id.clear
      @part_type_by_id.clear
      @total_cost = 0.0
      @total_input_tokens = 0
      @total_output_tokens = 0
      @first_text_seen = false
    end

    # Bring the live reply up to a recovered/polled exchange snapshot and
    # notify observers for new or changed parts. This is the streaming
    # counterpart to replace_parts: when the SSE connection ends before
    # OpenCode's multi-message tool loop has produced final text, Turn polls
    # the message exchange. Those recovered parts still need to hit Turbo as
    # incremental append/update events, not only the final row replacement.
    def sync_recovered_parts(recovered_parts)
      Array(recovered_parts).each_with_index do |part, index|
        next if @parts[index] == part

        part = deep_dup_part(part)
        if index < @parts.length
          @parts[index] = part
          notify_recovered_part_updated(part, index)
        else
          @parts << part
          notify(:part_added, part: part, index: index)
          notify_recovered_part_updated(part, index)
        end

        @first_text_seen ||= part["type"] == "text" && part["content"].present?
      end
    end

    # Record a part that originated OUTSIDE the OpenCode event stream —
    # used when an observer synthesizes a part (e.g., a session error
    # notice) that isn't a real message.part.* event but should still
    # appear in the persisted parts_json. Returns the new index.
    #
    # Does NOT fire part_added — the injecting observer has already done
    # whatever rendering it needed. Other observers can poll `parts` if
    # they care about injected content.
    def inject_part(part_hash)
      @parts << part_hash
      @parts.size - 1
    end

    def first_text_seen?
      @first_text_seen
    end

    def tool_count
      @parts.count { |p| p["type"] == "tool" }
    end

    # The denormalized result once streaming completes, matching the
    # shape jobs persist to the message table: full_text for :content,
    # reasoning_text for :reasoning, tool_parts for :tool_calls_json,
    # and parts_json for :parts_json.
    def result
      self.class.distill(@parts)
    end

    # Pure function: given a parts array, return the denormalized result
    # as an Opencode::Reply::Result value object. Exposed so a recovery
    # path (fetch messages from the session API and map them through
    # ResponseParser.extract_interleaved_parts) produces the same shape
    # as live streaming.
    def self.distill(parts)
      Result.new(
        parts_json: parts,
        full_text: join_content(parts, "text"),
        reasoning_text: join_content(parts, "reasoning"),
        tool_parts: parts.select { |p| p["type"] == "tool" && TERMINAL_TOOL_STATUSES.include?(p["status"]) }
      )
    end

    def self.join_content(parts, type)
      parts.select { |p| p["type"] == type }.map { |p| p["content"].to_s }.join("\n\n")
    end
    private_class_method :join_content

    private

    def apply_part_delta(event)
      field = event.dig(:properties, :field)
      return unless %w[text reasoning].include?(field)

      part_id = event.dig(:properties, :partID)
      delta = event.dig(:properties, :delta).to_s
      return if delta.empty?

      index = @part_index_by_id[part_id]
      if index.nil?
        # Delta before part.updated. Pre-1.2 OpenCode streams occasionally
        # emit in this order; downstream part.updated for this id will
        # reconcile via reconcile_final_content.
        type = @part_type_by_id[part_id] || (field == "reasoning" ? "reasoning" : "text")
        index = append_part({ "type" => type, "content" => +"" }, part_id: part_id)
      end

      @parts[index]["content"] << delta
      @first_text_seen ||= (field == "text" && @parts[index]["type"] == "text")

      notify(:part_changed, part: @parts[index], index: index, delta: delta)
    end

    def apply_part_updated(event)
      part = event.dig(:properties, :part) || {}
      part_id = part[:id]
      part_type = part[:type]

      case part_type
      when "step-finish"
        cost = part[:cost].to_f
        tokens = part[:tokens] || {}
        @total_cost += cost
        @total_input_tokens += tokens[:input].to_i
        @total_output_tokens += tokens[:output].to_i
        notify(:step_finished, cost: cost, tokens: tokens)
      when "text", "reasoning"
        @part_type_by_id[part_id] = part_type if part_id
        if @part_index_by_id.key?(part_id)
          reconcile_final_content(part_id, part)
        elsif part[:text].present?
          # Extreme tail-drop path: part.updated carries the full text
          # but no deltas ever arrived. Materialize it as a one-shot part
          # so the content isn't lost.
          append_part({ "type" => part_type, "content" => part[:text].dup }, part_id: part_id)
        end
      when "tool"
        register_tool(part_id, part) unless @part_index_by_id.key?(part_id)
        apply_tool_state(part_id, part)
      end
    end

    def apply_message_updated(event)
      info = event.dig(:properties, :info)
      return unless info.is_a?(Hash)

      @info = info
      notify(:message_updated, info: info)
    end

    def apply_session_status(event)
      case event.dig(:properties, :status, :type)
      when "retry"
        notify(:session_retried,
          attempt: event.dig(:properties, :status, :attempt),
          message: event.dig(:properties, :status, :message).to_s)
      end
    end

    def apply_session_error(event)
      error = event.dig(:properties, :error) || {}
      name = error[:name].to_s
      message = error.dig(:data, :message).to_s
      text = [ name, message ].reject(&:blank?).join(": ")

      notify(:session_errored, text: text, raw: error)
    end

    # Close out a text/reasoning part: always fires :part_finalized so
    # observers can flush any throttled broadcast, and rewrites content if
    # part.updated carries an authoritative :text that diverges from the
    # deltas we accumulated (tail-drop safety net for providers like
    # z.ai GLM-5.1 that sometimes drop trailing deltas).
    def reconcile_final_content(part_id, part)
      index = @part_index_by_id[part_id]
      final = part[:text]
      return if final.blank?

      @parts[index]["content"] = final.dup unless @parts[index]["content"] == final
      notify(:part_finalized, part: @parts[index], index: index)
    end

    def register_tool(part_id, part)
      append_part({
        "type" => "tool",
        "tool" => part[:tool],
        "status" => part.dig(:state, :status)
      }, part_id: part_id)
    end

    # Merge an incoming `message.part.updated` event state into the
    # existing tool record. Delegates the field-by-field shape to
    # Opencode::ToolPart so the streaming and recovery paths share one
    # canonical definition of what a tool part looks like.
    def apply_tool_state(part_id, part)
      index = @part_index_by_id[part_id]
      return unless index

      record = @parts[index]
      Opencode::ToolPart.merge_streaming_state(record, part)
      @todo_part_index = index if todo_tool_part?(record)

      notify(:tool_progressed,
        part: record,
        index: index,
        status: record["status"],
        raw: part)

      drain_pending_question_payload(record)
    end

    def apply_todo_updated(event)
      todos = event.dig(:properties, :todos) || []
      notify(:todos_changed, todos: todos)
      return unless todos.is_a?(Array)

      canonical_todos = Opencode::Todo.canonicalize_all(todos)

      index = current_todo_part_index
      if index
        refresh_existing_todo_part(index, canonical_todos, event)
      else
        @todo_part_index = append_part(Opencode::PartSource.stamp({
          "type"   => "tool",
          "tool"   => "todowrite",
          "status" => "completed",
          "input"  => { "todos" => canonical_todos }
        }, source: Opencode::PartSource::TODO_UPDATED))
      end
    end

    # Refresh path for an existing todo part — either a real `todowrite`
    # tool part materialized from message.part.updated, OR our own
    # previously-stamped stream-only part. Either way we MERGE into
    # `input` rather than replace it, so any non-todos fields a real
    # tool call carried survive the refresh.
    #
    # We intentionally do NOT touch `part["title"]`. Upstream opencode's
    # title is "N remaining todos" (a progress indicator like "2 todos"
    # when 2 of 3 are still incomplete, "0 todos" when all done) and is
    # set on the original message.part.updated event. Stomping it with
    # our own value would clobber that semantic.
    def refresh_existing_todo_part(index, canonical_todos, event)
      part = @parts[index]
      part["status"] = part["status"].presence || "completed"
      part["input"] = (part["input"] || {}).merge("todos" => canonical_todos)
      notify(:tool_progressed, part: part, index: index, status: part["status"], raw: event)
    end

    def current_todo_part_index
      return @todo_part_index if @todo_part_index && todo_tool_part?(@parts[@todo_part_index])

      @todo_part_index = @parts.rindex { |part| todo_tool_part?(part) }
    end

    def todo_tool_part?(part)
      part.is_a?(Hash) && part["type"] == "tool" && TODO_TOOLS.include?(part["tool"].to_s)
    end

    def deep_dup_part(part)
      case part
      when Hash
        part.transform_values { |value| deep_dup_part(value) }
      when Array
        part.map { |value| deep_dup_part(value) }
      else
        part.duplicable? ? part.dup : part
      end
    end

    def notify_recovered_part_updated(part, index)
      case part["type"]
      when "tool"
        notify(:tool_progressed, part: part, index: index, status: part["status"], raw: {})
      when "text", "reasoning"
        notify(:part_finalized, part: part, index: index)
      end
    end

    def append_part(part_hash, part_id: nil)
      @parts << part_hash
      index = @parts.size - 1
      if part_id
        @part_index_by_id[part_id] = index
        @part_type_by_id[part_id] = part_hash["type"]
      end
      notify(:part_added, part: @parts[index], index: index)
      index
    end

    def notify(callback, **payload)
      @observers.each do |observer|
        observer.public_send(callback, **payload) if observer.respond_to?(callback)
      end
    end

    # --- interactive prompts -----------------------------------------

    def apply_question_asked(event)
      request = (event[:properties] || {}).dup
      return unless request[:id].is_a?(String)

      @prompts.record_question(request)

      if (tool = request[:tool])
        @pending_question_payloads[[ tool[:messageID].to_s, tool[:callID].to_s ]] = request
      end

      merge_pending_question_into_existing_tool_part(request)

      notify(:question_asked, request: request, raw: event)
    end

    def apply_question_replied(event)
      props = event[:properties] || {}
      request_id = props[:requestID]
      answers = props[:answers] || []
      return unless request_id

      asked_at = @prompts.asked_at(request_id)
      @prompts.resolve(request_id)
      notify(:question_replied, request_id: request_id, answers: answers, raw: event, asked_at: asked_at)
    end

    def apply_question_rejected(event)
      props = event[:properties] || {}
      request_id = props[:requestID]
      return unless request_id

      asked_at = @prompts.asked_at(request_id)
      @prompts.resolve(request_id)
      notify(:question_rejected, request_id: request_id, raw: event, asked_at: asked_at)
    end

    def apply_permission_asked(event)
      request = (event[:properties] || {}).dup
      return unless request[:id].is_a?(String)

      @prompts.record_permission(request)
      notify(:permission_asked, request: request, raw: event)
    end

    def apply_permission_replied(event)
      props = event[:properties] || {}
      request_id = props[:requestID]
      return unless request_id

      asked_at = @prompts.asked_at(request_id)
      @prompts.resolve(request_id)
      notify(:permission_replied,
        request_id: request_id,
        reply: props[:reply],
        raw: event,
        asked_at: asked_at)
    end

    # Merge a pending question payload into the matching tool part if
    # the tool part exists. Reads record["callID"] / record["messageID"]
    # which are persisted by ToolPart.merge_streaming_state (per Task 2.0).
    # Decorates the part's "input" with both the question content AND the
    # opencode identifiers the view + controller need.
    #
    # Called from two paths:
    #   1. apply_question_asked, when the tool part already exists
    #   2. apply_tool_state, when the tool part arrives AFTER question.asked
    def merge_pending_question_into_existing_tool_part(request)
      tool = request[:tool]
      return unless tool

      call_id = tool[:callID].to_s
      message_id = tool[:messageID].to_s
      return if call_id.empty?

      index = @parts.index do |part|
        part.is_a?(Hash) && part["type"] == "tool" && part["tool"] == "question" &&
          part["callID"] == call_id
      end
      return unless index

      part = @parts[index]
      # Stringify keys so the in-memory shape matches what's persisted
      # via the parts_json JSON column round-trip. Otherwise direct-render
      # callers (e.g., integration tests, future debug tooling) hit
      # symbol-keyed nested hashes while the partials read string keys —
      # silent broken HTML.
      input = (part["input"] || {}).merge(
        "questions" => deep_stringify_keys(request[:questions]),
        "opencode_request_id" => request[:id],
        "opencode_message_id" => message_id,
        "opencode_call_id" => call_id
      )
      part["input"] = input

      notify(:tool_progressed, part: part, index: index, status: part["status"],
        raw: { type: "question.asked.synthesized" })
    end

    # Order-race fix: if question.asked arrived before this tool part,
    # its payload is parked in @pending_question_payloads keyed by
    # {messageID, callID}. Drain it now so the part's input carries
    # the questions + opencode_* identifiers the view expects.
    def drain_pending_question_payload(record)
      return unless record["tool"] == "question" && record["callID"].present?

      key = [ record["messageID"].to_s, record["callID"].to_s ]
      pending = @pending_question_payloads.delete(key)
      merge_pending_question_into_existing_tool_part(pending) if pending
    end

    # Recursively converts hash keys to strings — used at the SSE/JSON
    # boundary so in-memory parts match the shape they have after a
    # parts_json (JSON column) round-trip. Same semantics as Rails'
    # Hash#deep_stringify_keys but iterates arrays too.
    def deep_stringify_keys(obj)
      case obj
      when Hash then obj.each_with_object({}) { |(k, v), h| h[k.to_s] = deep_stringify_keys(v) }
      when Array then obj.map { |x| deep_stringify_keys(x) }
      else obj
      end
    end
  end
end
