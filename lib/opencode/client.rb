# frozen_string_literal: true

require "net/http"
require "json"
require "base64"

module Opencode
  # HTTP client for OpenCode REST API.
  # Thread safety: Each instance creates its own Net::HTTP connection.
  # Do NOT share instances across threads. Create per-job.
  class Client
    attr_reader :directory

    def initialize(
      base_url: ENV["OPENCODE_BASE_URL"] || "http://localhost:4096",
      password: ENV["OPENCODE_SERVER_PASSWORD"],
      timeout: (ENV["OPENCODE_TIMEOUT"] || 120).to_i,
      directory: nil,
      workspace: nil
    )
      @uri = URI.parse(base_url)
      @password = password
      @timeout = timeout || 120
      @directory = directory
      @workspace = workspace
    end

    def create_session(
      title: nil,
      permissions: nil,
      parent_id: nil,
      agent: nil,
      model: nil,
      metadata: nil,
      workspace_id: nil
    )
      body = {
        title: title,
        permission: permissions,
        parentID: parent_id,
        agent: agent,
        model: format_session_model(model),
        metadata: metadata,
        workspaceID: workspace_id
      }.compact
      post("/session", body)
    end

    def send_message(
      session_id, text,
      parts: nil,
      model: nil,
      agent: nil,
      system: nil,
      message_id: nil,
      no_reply: nil,
      tools: nil,
      format: nil,
      variant: nil
    )
      body = prompt_payload(
        text,
        parts: parts,
        model: model,
        agent: agent,
        system: system,
        message_id: message_id,
        no_reply: no_reply,
        tools: tools,
        format: format,
        variant: variant
      )
      post("/session/#{session_id}/message", body)
    end

    def send_message_async(
      session_id, text,
      parts: nil,
      model: nil,
      agent: nil,
      system: nil,
      message_id: nil,
      no_reply: nil,
      tools: nil,
      format: nil,
      variant: nil
    )
      body = prompt_payload(
        text,
        parts: parts,
        model: model,
        agent: agent,
        system: system,
        message_id: message_id,
        no_reply: no_reply,
        tools: tools,
        format: format,
        variant: variant
      )
      post("/session/#{session_id}/prompt_async", body)
    end

    # Block-form streaming — the headline API for callers who want the
    # full async-prompt + SSE-loop + final-exchange-merge flow in one
    # call. Returns the final Opencode::Reply::Result value object once
    # the agent finishes.
    #
    #   reply = client.stream(session_id, "Explain monads") do |part|
    #     print part["content"] if part["type"] == "text"
    #   end
    #   reply.full_text   # => the final accumulated text
    #   reply.tool_parts  # => array of terminal tool parts
    #
    # The block is invoked every time a part is added, grows, finalizes,
    # or (for tool parts) advances state — i.e., whenever a user-visible
    # change happens. The block receives the current `part` hash (string
    # keys: "type", "content", "tool", "status", "input", ...).
    #
    # If you need raw events (every server.* tick, todo.updated, prompt
    # asked/replied, etc.), use #stream_events instead.
    #
    # Optional kwargs are forwarded to send_message_async — model, agent,
    # system prompt override, and the SSE pacing knobs supported by
    # stream_events.
    def stream(
      session_id, text,
      model: nil, agent: nil, system: nil, message_id: nil,
      stream_timeout: 600,
      first_event_timeout: 120,
      idle_stream_timeout: nil,
      on_activity_tick: nil,
      &block
    )
      reply = Opencode::Reply.new
      reply.add_observer(StreamBlockObserver.new(&block)) if block_given?

      # Opening the event stream after prompt_async leaves a race where a fast
      # turn can emit (and finish) before the client is subscribed. Wait for
      # OpenCode's initial server.connected SSE frame, then submit the prompt
      # exactly once. Reconnects invoke on_subscribed again, so mark the attempt
      # before the POST: an ambiguous prompt response must never cause the same
      # turn to be submitted twice.
      prompt_attempted = false
      on_subscribed = lambda do
        next false if prompt_attempted

        prompt_attempted = true
        send_message_async(
          session_id, text,
          model: model, agent: agent, system: system, message_id: message_id
        )
        true
      end

      consume_event_stream(
        session_id: session_id,
        timeout: stream_timeout,
        first_event_timeout: first_event_timeout,
        idle_stream_timeout: idle_stream_timeout,
        reply: reply,
        on_activity_tick: on_activity_tick,
        on_subscribed: on_subscribed
      ) do |event|
        reply.apply(event)
      end

      merge_final_exchange(session_id, reply)
      reply.result
    end

    def list_sessions
      uri = build_uri("/session")
      request = Net::HTTP::Get.new(uri)
      execute(request)
    end

    def update_session(session_id, permissions:)
      patch("/session/#{session_id}", { permission: permissions })
    end

    def children(session_id)
      uri = build_uri("/session/#{session_id}/children")
      request = Net::HTTP::Get.new(uri)
      execute(request)
    end

    def delete_session(session_id)
      uri = build_uri("/session/#{session_id}")
      request = Net::HTTP::Delete.new(uri)
      execute(request)
    end

    def session_status
      uri = build_uri("/session/status")
      request = Net::HTTP::Get.new(uri)
      execute(request)
    end

    def get_messages(session_id)
      uri = build_uri("/session/#{session_id}/message")
      request = Net::HTTP::Get.new(uri)
      execute(request)
    end

    def abort_session(session_id)
      post("/session/#{session_id}/abort", {})
    end

    def reply_question(request_id:, answers:)
      post("/question/#{request_id}/reply", { answers: answers })
    end

    def reject_question(request_id:)
      post("/question/#{request_id}/reject", {})
    end

    def reply_permission(request_id:, reply:, message: nil)
      body = { reply: reply }
      body[:message] = message if message.present?
      post("/permission/#{request_id}/reply", body)
    end

    # Returns pending question requests as an Array of Hashes with
    # SYMBOL keys, consistent with every other endpoint that flows
    # through handle_response (e.g., health, list_sessions, get_messages).
    # Callers that compare against persisted JSON column data should
    # symbolize their side, not desymbolize this side.
    def list_questions
      uri = build_uri("/question")
      request = Net::HTTP::Get.new(uri)
      add_auth_header(request)

      response = Opencode::Instrumentation.instrument("opencode.request", method: request.method, path: request.path) do
        http_client.request(request)
      end

      unless response.code.to_i.between?(200, 299)
        raise ServerError, "list_questions failed: HTTP #{response.code} — #{response.body.to_s[0, 200]}"
      end

      return [] if response.body.blank?
      JSON.parse(response.body, symbolize_names: true)
    rescue JSON::ParserError => e
      raise ServerError, "list_questions returned invalid JSON: #{e.message}"
    rescue Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout => e
      raise TimeoutError, "OpenCode timeout after #{@timeout}s: #{e.message}"
    rescue Errno::ECONNREFUSED, SocketError => e
      raise ConnectionError, "OpenCode unreachable: #{e.message}"
    end

    def health
      uri = build_uri("/global/health", scoped: false)
      request = Net::HTTP::Get.new(uri)
      execute(request)
    end

    MAX_SSE_BUFFER = 1_048_576 # 1 MB — safety valve against pathological server responses
    SSE_RECONNECT_DELAY = 0.1
    TRANSIENT_SSE_ERRORS = [
      EOFError,
      IOError,
      Net::OpenTimeout,
      Net::ReadTimeout,
      Errno::ECONNREFUSED,
      Errno::ECONNRESET,
      Errno::EPIPE
    ].freeze

    # Opens SSE connection to GET /event, yields parsed events filtered by session_id.
    # Blocks until the session reports idle or timeout, reconnecting across
    # dropped event-stream connections. Current OpenCode emits
    # `session.status` with `status.type == "idle"`; older versions emitted the
    # standalone `session.idle` event, so both remain terminal.
    #
    # first_event_timeout: seconds to wait for a session-specific event before
    # declaring the session stale. Server heartbeats don't count — they're global
    # keep-alives that flow regardless of session state.
    #
    # Default 120s rather than the more aggressive 30s used originally:
    # slow-thinking reasoning models (Kimi K2, GPT-5 with extended thinking,
    # etc.) routinely spend 30-90s of pure reasoning before emitting their
    # first `message.part.*` event, especially on cold sessions with long
    # system prompts. 30s false-positive trips on legitimate first turns
    # and converts them to `StaleSessionError`; 120s catches genuine zombies
    # without nuking real reasoning. Callers that know their agent is
    # short-prompt + fast can pass a lower value.
    #
    # idle_stream_timeout: seconds to wait BETWEEN meaningful events once
    # the session has started producing them. Default nil = no check
    # (preserves the overall `timeout` ceiling behavior). Opt-in heartbeat
    # watchdog for callers whose user-facing surface needs to fail fast
    # rather than sit forever when an upstream LLM stream wedges mid-turn.
    # Distinct from first_event_timeout (which only protects cold-start)
    # and from the overall `timeout` ceiling of 600s (which is forgiving
    # — a hung stream holding a thread for 10 minutes is already a bad
    # UX). When the window is exceeded the call raises
    # Opencode::IdleStreamError, which the caller is expected to catch and
    # translate into a user-visible error / retry affordance.
    def stream_events(session_id:, timeout: 600, first_event_timeout: 120,
                       idle_stream_timeout: nil,
                       reply: nil, on_activity_tick: nil, &block)
      consume_event_stream(
        session_id: session_id,
        timeout: timeout,
        first_event_timeout: first_event_timeout,
        idle_stream_timeout: idle_stream_timeout,
        reply: reply,
        on_activity_tick: on_activity_tick,
        &block
      )
    end

    private def consume_event_stream(session_id:, timeout:, first_event_timeout:,
                                     idle_stream_timeout:, reply:, on_activity_tick:,
                                     on_subscribed: nil, &block)
      uri = build_uri("/event")
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      first_event_deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + first_event_timeout
      received_session_event = false
      last_meaningful_event_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      loop do
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        deadline = check_deadline_or_suspend(now, deadline, timeout, reply)

        # NOTE: first_event_deadline is *not* suspension-eligible. If the agent
        # never gets started we want to fail fast — a session that's blocked on
        # a prompt has, by definition, already produced events.
        if !received_session_event && now > first_event_deadline
          raise StaleSessionError, "No events for session #{session_id} within #{first_event_timeout}s"
        end

        if idle_stream_timeout && received_session_event &&
           (now - last_meaningful_event_at) > idle_stream_timeout
          raise IdleStreamError,
                "No meaningful events for session #{session_id} within #{idle_stream_timeout}s " \
                "(SSE heartbeats still arriving — upstream likely wedged mid-turn)"
        end

        request = Net::HTTP::Get.new(uri)
        request["Accept"] = "text/event-stream"
        request["Cache-Control"] = "no-cache"
        add_auth_header(request)

        http = Net::HTTP.new(@uri.host, @uri.port)
        http.use_ssl = @uri.scheme == "https"
        http.open_timeout = 10
        http.read_timeout = 30

        subscription_callback_error = nil
        subscription_ready = on_subscribed.nil?
        begin
          buffer = String.new

          http.request(request) do |response|
            unless response.is_a?(Net::HTTPSuccess)
              raise ServerError, "SSE connection failed: HTTP #{response.code}"
            end

            response.read_body do |chunk|
              now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
              deadline = check_deadline_or_suspend(now, deadline, timeout, reply)

              if !received_session_event && now > first_event_deadline
                raise StaleSessionError, "No events for session #{session_id} within #{first_event_timeout}s"
              end

              if idle_stream_timeout && received_session_event &&
                 (now - last_meaningful_event_at) > idle_stream_timeout
                raise IdleStreamError,
                      "No meaningful events for session #{session_id} within #{idle_stream_timeout}s " \
                      "(SSE heartbeats still arriving — upstream likely wedged mid-turn)"
              end

              buffer << chunk
              if buffer.bytesize > MAX_SSE_BUFFER
                raise ServerError, "SSE buffer exceeded #{MAX_SSE_BUFFER} bytes"
              end

              while (idx = buffer.index("\n\n"))
                raw_event = buffer.slice!(0, idx + 2)
                event = parse_sse_event(raw_event, session_id)
                next unless event

                unless subscription_ready
                  # Every supported OpenCode server starts /event with this
                  # frame. Receiving it proves the stream body is flowing; on
                  # current servers the bus listener is registered eagerly,
                  # and on older lazy-stream servers it is the strongest
                  # available readiness handshake before prompting.
                  next unless event[:type] == "server.connected"

                  begin
                    turn_started = on_subscribed.call
                  rescue StandardError => error
                    # Prompt submission happens inside the open SSE response.
                    # Do not mistake its transport failure for an SSE disconnect
                    # and hide it behind a reconnect/first-event timeout.
                    subscription_callback_error = error
                    raise
                  end
                  if turn_started
                    # Before this fix stream_events began only after the prompt
                    # POST returned. Preserve those timeout semantics: the turn
                    # and first-session-event windows begin after prompt_async
                    # succeeds, not while establishing the readiness handshake.
                    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
                    deadline = started_at + timeout
                    first_event_deadline = started_at + first_event_timeout
                    last_meaningful_event_at = started_at
                  end
                  subscription_ready = true
                end

                unless event[:type]&.start_with?("server.")
                  received_session_event = true
                  last_meaningful_event_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
                end

                # Tick activity on EVERY event, including server.heartbeat —
                # that's the whole point: a healthy long wait (user thinking
                # for 30 minutes) keeps the container warm via heartbeats so
                # the reaper doesn't kill it mid-wait.
                on_activity_tick&.call(event)
                block.call(event)
                return if terminal_session_event?(event)
              end
            end
          end
        rescue *TRANSIENT_SSE_ERRORS
          raise if subscription_callback_error

          # Treat transport-level SSE disconnects like clean EOF: reconnect
          # until an idle session event, the overall timeout, or first-event
          # timeout.
        ensure
          begin
            http&.finish if http&.started?
          rescue IOError
            # Connection already closed — network partition or server shutdown
          end
        end

        cutoff = received_session_event ? deadline : first_event_deadline
        sleep_for = [ SSE_RECONNECT_DELAY, cutoff - Process.clock_gettime(Process::CLOCK_MONOTONIC) ].min
        if sleep_for.positive?
          sleep sleep_for
        end
      end
    end

    def close
      @http&.finish if @http&.started?
    rescue IOError
      # already closed
    end

    private

    # Best-effort merge of the polled message exchange into the live
    # reply. Catches the stream-only / poll-only asymmetry — todo.updated
    # is poll-only on some opencode versions; pure-streaming would miss
    # the terminal todo state otherwise. If the session API is also down
    # at this point (network partition, container teardown mid-call), we
    # silently keep whatever the stream accumulated rather than raising;
    # the caller's reply is still a usable Result either way.
    def merge_final_exchange(session_id, reply)
      exchange = get_messages(session_id)
      polled = current_turn_parts(exchange)
      return if polled.empty?

      merged = merge_stream_only_parts(reply.result.parts_json, polled)
      reply.sync_recovered_parts(merged)
      # sync_recovered_parts intentionally never deletes live parts because it
      # is also used during mid-stream recovery. This is the terminal poll, so
      # the wire snapshot is authoritative: remove any replayed trailing wire
      # part after observers have seen recovered additions/updates.
      reply.replace_parts(merged) unless reply.result.parts_json == merged
    rescue Opencode::Error
      # Stream's result is still complete; the merge was a polish, not a
      # requirement.
    end

    # Healthy wait: opencode is suspended on a question/permission deferred
    # and heartbeats are keeping the connection alive. Reset the deadline
    # to "from now" so the full stuck-stream protection is restored once
    # the prompt resolves. Otherwise apply the normal deadline check.
    def check_deadline_or_suspend(now, deadline, timeout, reply)
      return now + timeout if reply&.prompt_blocked?
      raise TimeoutError, "SSE stream timed out after #{timeout}s" if now > deadline

      deadline
    end

    def terminal_session_event?(event)
      return true if event[:type] == "session.idle"
      return false unless event[:type] == "session.status"

      status = event.dig(:properties, :status)
      status = status[:type] || status["type"] if status.is_a?(Hash)
      status == "idle"
    end

    # OpenCode persists one assistant message per model step. A tool loop can
    # therefore produce several assistant messages for one user turn (for
    # example skill -> task -> final text). Reconcile the complete current turn
    # instead of aligning the live parts array with only the last assistant
    # message, which corrupts tool parts and duplicates final text.
    def current_turn_parts(exchange)
      messages = Array(exchange)
      last_user_index = messages.rindex { |message| message.dig(:info, :role) == "user" }
      current_turn = last_user_index ? messages.drop(last_user_index + 1) : messages

      current_turn
        .select { |message| message.dig(:info, :role) == "assistant" }
        .flat_map { |message| Opencode::ResponseParser.extract_interleaved_parts(message) }
    end

    def merge_stream_only_parts(stream_parts, wire_parts)
      remaining_wire = Array(wire_parts).dup
      merged = []

      Array(stream_parts).each do |part|
        if Opencode::PartSource.stream_only?(part)
          merged << part
        elsif remaining_wire.any?
          merged << remaining_wire.shift
        end
      end

      merged.concat(remaining_wire)
    end

    def prompt_payload(text, parts:, model:, agent:, system:, message_id:, no_reply:, tools:, format:, variant:)
      message_parts = parts || [ { type: "text", text: text } ]
      {
        messageID: message_id,
        parts: message_parts,
        model: format_model(model),
        agent: agent,
        noReply: no_reply,
        tools: tools,
        format: format,
        system: system,
        variant: variant
      }.compact
    end

    def format_model(model)
      return nil unless model
      return model if model.is_a?(Hash)

      provider, model_id = model.split("/", 2)
      { providerID: provider, modelID: model_id }
    end

    def format_session_model(model)
      return nil unless model
      return model if model.is_a?(Hash)

      provider, model_id = model.split("/", 2)
      { providerID: provider, id: model_id }
    end

    def post(path, body)
      uri = build_uri(path)
      request = Net::HTTP::Post.new(uri)
      request.body = body.to_json
      execute(request)
    end

    def patch(path, body)
      uri = build_uri(path)
      request = Net::HTTP::Patch.new(uri)
      request.body = body.to_json
      execute(request)
    end

    def build_uri(path, scoped: true)
      uri = @uri.dup
      uri.path = path

      if scoped
        query = URI.decode_www_form(uri.query.to_s)
        query << [ "directory", @directory ] if @directory.present?
        query << [ "workspace", @workspace ] if @workspace.present?
        uri.query = query.any? ? URI.encode_www_form(query) : nil
      end

      uri
    end

    def add_auth_header(request)
      request["Content-Type"] = "application/json"
      if @password.present?
        request["Authorization"] = "Basic #{Base64.strict_encode64("opencode:#{@password}")}"
      end
    end

    def execute(request)
      add_auth_header(request)

      response = nil
      result = Opencode::Instrumentation.instrument("opencode.request", method: request.method, path: request.path) do
        response = http_client.request(request)
        handle_response(response)
      end

      result
    rescue Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout => e
      raise TimeoutError, "OpenCode timeout after #{@timeout}s: #{e.message}"
    rescue Errno::ECONNREFUSED, SocketError => e
      raise ConnectionError, "OpenCode unreachable: #{e.message}"
    end

    def http_client
      @http ||= Net::HTTP.new(@uri.host, @uri.port).tap do |http|
        http.use_ssl = @uri.scheme == "https"
        http.open_timeout = 10
        http.read_timeout = @timeout
        http.write_timeout = 30
      end
    end

    def parse_sse_event(raw, session_id)
      data_line = raw.lines.find { |l| l.start_with?("data: ") }
      return nil unless data_line

      json = JSON.parse(data_line.sub("data: ", "").strip, symbolize_names: true)

      event_session = json.dig(:properties, :sessionID) ||
                      json.dig(:properties, :info, :sessionID) ||
                      json.dig(:properties, :part, :sessionID)

      return json if json[:type] == "server.heartbeat"
      return json if json[:type] == "server.connected"
      return nil unless event_session == session_id

      json
    rescue JSON::ParserError
      nil
    end

    def handle_response(response)
      return {} if response.code.to_i == 204

      body = if response.body.present?
        JSON.parse(response.body, symbolize_names: true)
      else
        {}
      end

      case response.code.to_i
      when 200..299 then body
      when 400 then raise BadRequestError.new(error_message(body, "Bad request"), response: body)
      when 404 then raise SessionNotFoundError.new(error_message(body, "Session not found"), response: body)
      when 500..599 then raise ServerError.new(error_message(body, "Server error"), response: body)
      else raise Error.new("Unexpected response: #{response.code}", response: body)
      end
    rescue JSON::ParserError
      raise ServerError.new("Invalid JSON from OpenCode (HTTP #{response.code}): #{response.body&.truncate(200)}")
    end

    # OpenCode HTTP error bodies use a wrapped shape: { name:, data: { message:, kind?: } }.
    # v1.14.51 stopped exposing internal defect details from the HTTP API, so
    # `body[:message]` is no longer populated for errors — only `body[:data][:message]`.
    # We read both to keep older mock servers working in tests.
    def error_message(body, fallback)
      body.dig(:data, :message) || body[:message] || fallback
    end
  end

  # Internal Reply observer that bridges Reply's multi-callback protocol
  # to a single user-supplied block for Client#stream. Each part-level
  # callback (part_added, part_changed, part_finalized, tool_progressed)
  # forwards the current part to the user's block.
  #
  # Non-part-level callbacks (step_finished, session_*, message_updated,
  # todos_changed, question_*, permission_*) are intentionally NOT
  # forwarded — they're either telemetry the gem owns internally, or
  # interactive-protocol concerns that callers route through
  # #stream_events directly when they need them.
  class StreamBlockObserver
    include Opencode::ReplyObserver

    def initialize(&block)
      @block = block
    end

    def part_added(part:, **)
      @block.call(part)
    end

    def part_changed(part:, **)
      @block.call(part)
    end

    def part_finalized(part:, **)
      @block.call(part)
    end

    def tool_progressed(part:, **)
      @block.call(part)
    end
  end
end
