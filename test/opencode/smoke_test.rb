# frozen_string_literal: true

require "test_helper"
require "timeout"

# End-to-end smoke test of the gem's public surface. Validates that the
# headline `client.stream(...)` API + Reply::Result + error model + the
# pluggable Instrumentation adapter all work against a fully mocked
# OpenCode server. This is the test we'd point at in the README to
# prove the postcard works.
class SmokeTest < Minitest::Test
  BASE = "http://opencode.test"
  PASSWORD = "test-secret"
  SESSION_ID = "ses_smoke_1"
  CONNECTED_EVENT = { type: "server.connected", properties: {} }.freeze

  def setup
    @client = Opencode::Client.new(
      base_url: BASE,
      password: PASSWORD,
      timeout: 5
    )
    Opencode::Instrumentation.adapter = nil
  end

  def test_VERSION_is_a_string
    assert_kind_of String, Opencode::VERSION
    assert_match(/\A\d+\.\d+\.\d+/, Opencode::VERSION)
  end

  def test_constants_are_loaded
    assert_equal "Opencode::Client", Opencode::Client.name
    assert_equal "Opencode::Reply", Opencode::Reply.name
    assert_equal "Opencode::Reply::Result", Opencode::Reply::Result.name
    assert_equal "Opencode::Error", Opencode::Error.name
    assert Opencode::ConnectionError < Opencode::Error
  end

  def test_health_endpoint_round_trip
    stub_request(:get, "#{BASE}/global/health")
      .to_return(status: 200, body: { healthy: true, version: "1.15.5" }.to_json,
                 headers: { "Content-Type" => "application/json" })

    response = @client.health
    assert_equal true, response[:healthy]
    assert_equal "1.15.5", response[:version]
  end

  def test_create_session_returns_session_id
    stub_request(:post, "#{BASE}/session")
      .with(body: { title: "smoke", permission: [] }.to_json)
      .to_return(status: 200, body: { id: SESSION_ID, title: "smoke" }.to_json,
                 headers: { "Content-Type" => "application/json" })

    response = @client.create_session(title: "smoke", permissions: [])
    assert_equal SESSION_ID, response[:id]
  end

  def test_create_session_sends_native_child_and_configuration_fields
    permissions = [ { permission: "skill", pattern: "*", action: "deny" } ]
    expected_body = {
      title: "curator",
      permission: permissions,
      parentID: "ses_parent",
      agent: "destination-list-curator",
      model: { providerID: "openrouter", id: "anthropic/claude-sonnet-4" },
      metadata: { run: "9" },
      workspaceID: "wrk_1"
    }

    stub_request(:post, "#{BASE}/session")
      .with(body: expected_body.to_json)
      .to_return(status: 200, body: { id: SESSION_ID }.to_json,
                 headers: { "Content-Type" => "application/json" })

    response = @client.create_session(
      title: "curator",
      permissions: permissions,
      parent_id: "ses_parent",
      agent: "destination-list-curator",
      model: "openrouter/anthropic/claude-sonnet-4",
      metadata: { run: "9" },
      workspace_id: "wrk_1"
    )

    assert_equal SESSION_ID, response[:id]
    assert_requested :post, "#{BASE}/session", body: expected_body.to_json, times: 1
  end

  def test_create_session_preserves_a_preformatted_model
    model = { providerID: "openai", id: "gpt-5.5", variant: "high" }

    stub_request(:post, "#{BASE}/session")
      .with(body: { model: model }.to_json)
      .to_return(status: 200, body: { id: SESSION_ID }.to_json,
                 headers: { "Content-Type" => "application/json" })

    response = @client.create_session(model: model)

    assert_equal SESSION_ID, response[:id]
    assert_requested :post, "#{BASE}/session", body: { model: model }.to_json, times: 1
  end

  def test_update_session_patches_permissions_and_returns_the_updated_session
    permissions = [
      { permission: "skill", pattern: "*", action: "deny" },
      { permission: "skill", pattern: "core-details", action: "allow" }
    ]

    stub_request(:patch, "#{BASE}/session/#{SESSION_ID}")
      .with(body: { permission: permissions }.to_json)
      .to_return(status: 200, body: { id: SESSION_ID, permission: permissions }.to_json,
                 headers: { "Content-Type" => "application/json" })

    response = @client.update_session(SESSION_ID, permissions: permissions)

    assert_equal SESSION_ID, response[:id]
    assert_equal permissions, response[:permission]
    assert_requested :patch, "#{BASE}/session/#{SESSION_ID}", times: 1
  end

  def test_send_message_async_returns_empty_body
    stub_request(:post, "#{BASE}/session/#{SESSION_ID}/prompt_async")
      .to_return(status: 204, body: "")

    response = @client.send_message_async(SESSION_ID, "ping")
    assert_equal({}, response)
  end

  def test_send_message_async_serializes_a_structured_child_prompt
    schema = {
      type: "object",
      properties: {
        requirement_suggestions: {
          type: "array",
          items: { type: "string" }
        }
      },
      required: [ "requirement_suggestions" ],
      additionalProperties: false
    }
    invocation_query =
      "Complete the bounded structured request from the preloaded worker skill and immutable Rails context."
    expected_body = {
      messageID: "msg_worker_1",
      parts: [ { type: "text", text: invocation_query } ],
      agent: "destination-list-curator",
      format: {
        type: "json_schema",
        schema: schema,
        retryCount: 0
      },
      system: "Immutable Rails context"
    }
    serialized_body = nil

    prompt = stub_request(:post, "#{BASE}/session/#{SESSION_ID}/prompt_async")
      .with(body: expected_body.to_json)
      .to_return do |request|
        serialized_body = request.body
        { status: 204, body: "" }
      end

    @client.send_message_async(
      SESSION_ID,
      invocation_query,
      agent: "destination-list-curator",
      system: "Immutable Rails context",
      message_id: "msg_worker_1",
      format: {
        type: "json_schema",
        schema: schema,
        retryCount: 0
      }
    )

    assert_equal expected_body.to_json, serialized_body
    assert_requested prompt, times: 1
  end

  def test_stream_returns_typed_Reply_Result_with_full_text
    stub_request(:post, "#{BASE}/session/#{SESSION_ID}/prompt_async")
      .to_return(status: 204, body: "")

    sse = [
      CONNECTED_EVENT,
      { type: "message.part.delta",
        properties: { sessionID: SESSION_ID, partID: "p1", field: "text", delta: "hello " } },
      { type: "message.part.delta",
        properties: { sessionID: SESSION_ID, partID: "p1", field: "text", delta: "world" } },
      { type: "session.status", properties: { sessionID: SESSION_ID, status: { type: "idle" } } }
    ].map { |e| "data: #{e.to_json}\n\n" }.join

    stub_request(:get, %r{#{Regexp.escape(BASE)}/event(\?.*)?\z})
      .to_return(status: 200, body: sse,
                 headers: { "Content-Type" => "text/event-stream" })

    stub_request(:get, "#{BASE}/session/#{SESSION_ID}/message")
      .to_return(status: 200, body: [].to_json,
                 headers: { "Content-Type" => "application/json" })

    parts_yielded = []
    reply = @client.stream(SESSION_ID, "ping") do |part|
      parts_yielded << part.dup
    end

    assert_kind_of Opencode::Reply::Result, reply
    assert_equal "hello world", reply.full_text
    # Struct value object supports both message and hash style access.
    assert_equal "hello world", reply[:full_text]
    refute_empty parts_yielded
  end

  def test_stream_waits_for_server_connected_before_posting_the_prompt
    request_order = []
    connection_count = 0
    terminal_event = {
      type: "session.status",
      properties: { sessionID: SESSION_ID, status: { type: "idle" } }
    }

    stub_request(:get, %r{#{Regexp.escape(BASE)}/event(\?.*)?\z})
      .to_return do
        connection_count += 1
        request_order << :sse_accepted
        events = if connection_count == 1
          [ { type: "server.heartbeat", properties: {} } ]
        else
          [ CONNECTED_EVENT, terminal_event ]
        end
        {
          status: 200,
          body: events.map { |event| "data: #{event.to_json}\n\n" }.join,
          headers: { "Content-Type" => "text/event-stream" }
        }
      end

    stub_request(:post, "#{BASE}/session/#{SESSION_ID}/prompt_async")
      .to_return do
        request_order << :prompt
        { status: 204, body: "" }
      end

    stub_request(:get, "#{BASE}/session/#{SESSION_ID}/message")
      .to_return(status: 200, body: [].to_json,
                 headers: { "Content-Type" => "application/json" })

    @client.stream(SESSION_ID, "ping", stream_timeout: 1, first_event_timeout: 1)

    assert_equal [ :sse_accepted, :sse_accepted, :prompt ], request_order
  end

  def test_stream_does_not_post_when_sse_subscription_is_rejected
    stub_request(:get, %r{#{Regexp.escape(BASE)}/event(\?.*)?\z})
      .to_return(status: 503, body: "unavailable")
    prompt = stub_request(:post, "#{BASE}/session/#{SESSION_ID}/prompt_async")
      .to_return(status: 204, body: "")

    error = assert_raises(Opencode::ServerError) do
      @client.stream(SESSION_ID, "ping", stream_timeout: 1, first_event_timeout: 1)
    end

    assert_match "SSE connection failed: HTTP 503", error.message
    assert_not_requested prompt
  end

  def test_stream_surfaces_prompt_timeout_without_reconnecting
    event_stream = stub_request(:get, %r{#{Regexp.escape(BASE)}/event(\?.*)?\z})
      .to_return(status: 200, body: "data: #{CONNECTED_EVENT.to_json}\n\n",
                 headers: { "Content-Type" => "text/event-stream" })
    prompt = stub_request(:post, "#{BASE}/session/#{SESSION_ID}/prompt_async")
      .to_raise(Net::ReadTimeout.new("prompt timed out"))

    error = assert_raises(Opencode::TimeoutError) do
      @client.stream(SESSION_ID, "ping", stream_timeout: 1, first_event_timeout: 1)
    end

    assert_match "OpenCode timeout after 5s", error.message
    assert_requested event_stream, times: 1
    assert_requested prompt, times: 1
  end

  def test_stream_reconnects_without_reposting_the_prompt
    first_connection = [
      CONNECTED_EVENT,
      { type: "server.heartbeat", properties: {} }
    ]
    second_connection = [
      CONNECTED_EVENT,
      {
        type: "message.part.delta",
        properties: { sessionID: SESSION_ID, partID: "p1", field: "text", delta: "once" }
      },
      {
        type: "session.status",
        properties: { sessionID: SESSION_ID, status: { type: "idle" } }
      }
    ]

    event_stream = stub_request(:get, %r{#{Regexp.escape(BASE)}/event(\?.*)?\z})
      .to_return(
        {
          status: 200,
          body: first_connection.map { |event| "data: #{event.to_json}\n\n" }.join,
          headers: { "Content-Type" => "text/event-stream" }
        },
        {
          status: 200,
          body: second_connection.map { |event| "data: #{event.to_json}\n\n" }.join,
          headers: { "Content-Type" => "text/event-stream" }
        }
      )
    prompt = stub_request(:post, "#{BASE}/session/#{SESSION_ID}/prompt_async")
      .to_return(status: 204, body: "")
    stub_request(:get, "#{BASE}/session/#{SESSION_ID}/message")
      .to_return(status: 200, body: [].to_json,
                 headers: { "Content-Type" => "application/json" })

    reply = @client.stream(SESSION_ID, "ping", stream_timeout: 1, first_event_timeout: 1)

    assert_equal "once", reply.full_text
    assert_requested event_stream, times: 2
    assert_requested prompt, times: 1
  end

  def test_stream_events_invokes_on_subscribed_once_after_connected_across_reconnects
    order = []
    connections = [
      [ CONNECTED_EVENT, { type: "server.heartbeat", properties: {} } ],
      [
        CONNECTED_EVENT,
        {
          type: "session.status",
          properties: { sessionID: SESSION_ID, status: { type: "idle" } }
        }
      ]
    ]

    event_stream = stub_request(:get, %r{#{Regexp.escape(BASE)}/event(\?.*)?\z})
      .to_return do
        events = connections.shift or raise "unexpected third SSE connection"
        order << :sse_accepted
        {
          status: 200,
          body: events.map { |event| "data: #{event.to_json}\n\n" }.join,
          headers: { "Content-Type" => "text/event-stream" }
        }
      end

    subscribed_calls = 0
    @client.stream_events(
      session_id: SESSION_ID,
      timeout: 1,
      first_event_timeout: 1,
      on_subscribed: -> {
        subscribed_calls += 1
        order << :prompt
        true
      }
    ) { |_event| }

    assert_equal 1, subscribed_calls
    assert_equal [ :sse_accepted, :prompt, :sse_accepted ], order
    assert_requested event_stream, times: 2
  end

  def test_stream_events_surfaces_on_subscribed_timeout_without_reconnecting
    event_stream = stub_request(:get, %r{#{Regexp.escape(BASE)}/event(\?.*)?\z})
      .to_return(status: 200, body: "data: #{CONNECTED_EVENT.to_json}\n\n",
                 headers: { "Content-Type" => "text/event-stream" })

    calls = 0
    error = assert_raises(Net::ReadTimeout) do
      @client.stream_events(
        session_id: SESSION_ID,
        timeout: 1,
        first_event_timeout: 1,
        on_subscribed: -> {
          calls += 1
          raise Net::ReadTimeout, "ambiguous prompt response"
        }
      ) { |_event| }
    end

    assert_equal "Net::ReadTimeout with \"ambiguous prompt response\"", error.message
    assert_equal 1, calls
    assert_requested event_stream, times: 1
  end

  def test_stream_events_accepts_standard_sse_framing_variants
    terminal_event = {
      type: "session.status",
      properties: { sessionID: SESSION_ID, status: { type: "idle" } }
    }
    connected_data = JSON.pretty_generate(CONNECTED_EVENT).lines(chomp: true)
      .map { |line| "data: #{line}\r\n" }
      .join
    body = ": readiness comment\r\nevent: message\r\n#{connected_data}\r\n" \
           "data:#{terminal_event.to_json}\r\r"

    event_stream = stub_request(:get, %r{#{Regexp.escape(BASE)}/event(\?.*)?\z})
      .to_return(status: 200, body: body,
                 headers: { "Content-Type" => "text/event-stream" })

    subscribed_calls = 0
    event_types = []
    @client.stream_events(
      session_id: SESSION_ID,
      timeout: 1,
      first_event_timeout: 1,
      on_subscribed: -> {
        subscribed_calls += 1
        true
      }
    ) { |event| event_types << event.fetch(:type) }

    assert_equal 1, subscribed_calls
    assert_equal [ "server.connected", "session.status" ], event_types
    assert_requested event_stream, times: 1
  end

  def test_stream_events_handles_a_bom_and_boundaries_split_across_chunks
    terminal_event = {
      type: "session.status",
      properties: { sessionID: SESSION_ID, status: { type: "idle" } }
    }
    body = "\uFEFF: initial comment\r\n\r\n" \
           "data: #{CONNECTED_EVENT.to_json}\r\n\r\n" \
           "data: #{terminal_event.to_json}\n\n"
    chunks = body.b.bytes.map { |byte| byte.chr(Encoding::BINARY) }

    response = Net::HTTPOK.new("1.1", "200", "OK")
    response.define_singleton_method(:read_body) do |&callback|
      chunks.each(&callback)
    end
    http = Object.new
    http.define_singleton_method(:use_ssl=) { |_value| }
    http.define_singleton_method(:open_timeout=) { |_value| }
    http.define_singleton_method(:read_timeout=) { |_value| }
    http.define_singleton_method(:request) do |_request, &callback|
      callback.call(response)
    end
    http.define_singleton_method(:started?) { false }

    subscribed_calls = 0
    event_types = []
    Net::HTTP.stub(:new, ->(_host, _port) { http }) do
      @client.stream_events(
        session_id: SESSION_ID,
        timeout: 1,
        first_event_timeout: 1,
        on_subscribed: -> {
          subscribed_calls += 1
          true
        }
      ) { |event| event_types << event.fetch(:type) }
    end

    assert_equal 1, subscribed_calls
    assert_equal [ "server.connected", "session.status" ], event_types
  end

  def test_stream_events_preserves_question_and_permission_wait_state
    events = [
      {
        type: "question.asked",
        properties: { id: "que_1", sessionID: SESSION_ID, questions: [] }
      },
      {
        type: "question.replied",
        properties: { requestID: "que_1", sessionID: SESSION_ID, answers: [ [ "yes" ] ] }
      },
      {
        type: "permission.asked",
        properties: { id: "per_1", sessionID: SESSION_ID, permission: "bash" }
      },
      {
        type: "permission.replied",
        properties: { requestID: "per_1", sessionID: SESSION_ID, reply: "once" }
      },
      {
        type: "session.status",
        properties: { sessionID: SESSION_ID, status: { type: "idle" } }
      }
    ]
    stub_request(:get, %r{#{Regexp.escape(BASE)}/event(\?.*)?\z})
      .to_return(
        status: 200,
        body: events.map { |event| "data: #{event.to_json}\n\n" }.join,
        headers: { "Content-Type" => "text/event-stream" }
      )

    reply = Opencode::Reply.new
    wait_states = []
    @client.stream_events(session_id: SESSION_ID, reply: reply) do |event|
      reply.apply(event)
      wait_states << reply.prompt_blocked?
    end

    assert_equal [ true, false, true, false, false ], wait_states
  end

  def test_prompt_wait_does_not_suspend_timeout_after_disconnect
    question = {
      type: "question.asked",
      properties: { id: "que_1", sessionID: SESSION_ID, questions: [] }
    }
    stub_request(:get, %r{#{Regexp.escape(BASE)}/event(\?.*)?\z})
      .to_return(
        status: 200,
        body: "data: #{question.to_json}\n\n",
        headers: { "Content-Type" => "text/event-stream" }
      ).then.to_raise(Errno::ECONNREFUSED)

    reply = Opencode::Reply.new
    assert_raises(Opencode::TimeoutError) do
      Timeout.timeout(0.5) do
        @client.stream_events(
          session_id: SESSION_ID,
          timeout: 0.01,
          first_event_timeout: 1,
          reply: reply
        ) { |event| reply.apply(event) }
      end
    end
  end

  def test_connected_prompt_wait_suspends_timeout_while_events_keep_arriving
    question = {
      type: "question.asked",
      properties: { id: "que_1", sessionID: SESSION_ID, questions: [] }
    }
    replied = {
      type: "question.replied",
      properties: { requestID: "que_1", sessionID: SESSION_ID, answers: [ [ "yes" ] ] }
    }
    idle = {
      type: "session.status",
      properties: { sessionID: SESSION_ID, status: { type: "idle" } }
    }

    response = Net::HTTPOK.new("1.1", "200", "OK")
    response.define_singleton_method(:read_body) do |&callback|
      callback.call("data: #{question.to_json}\n\n")
      sleep 0.02
      callback.call("data: #{replied.to_json}\n\n")
      callback.call("data: #{idle.to_json}\n\n")
    end
    http = Object.new
    http.define_singleton_method(:use_ssl=) { |_value| }
    http.define_singleton_method(:open_timeout=) { |_value| }
    http.define_singleton_method(:read_timeout=) { |_value| }
    http.define_singleton_method(:request) { |_request, &callback| callback.call(response) }
    http.define_singleton_method(:started?) { false }

    reply = Opencode::Reply.new
    Net::HTTP.stub(:new, ->(_host, _port) { http }) do
      @client.stream_events(
        session_id: SESSION_ID,
        timeout: 0.01,
        first_event_timeout: 1,
        reply: reply
      ) { |event| reply.apply(event) }
    end
  end

  def test_stream_block_is_optional
    stub_request(:post, "#{BASE}/session/#{SESSION_ID}/prompt_async")
      .to_return(status: 204, body: "")

    sse = [
      CONNECTED_EVENT,
      { type: "message.part.delta",
        properties: { sessionID: SESSION_ID, partID: "p1", field: "text", delta: "ack" } },
      { type: "session.idle", properties: { sessionID: SESSION_ID } }
    ].map { |e| "data: #{e.to_json}\n\n" }.join

    stub_request(:get, %r{#{Regexp.escape(BASE)}/event(\?.*)?\z})
      .to_return(status: 200, body: sse,
                 headers: { "Content-Type" => "text/event-stream" })

    stub_request(:get, "#{BASE}/session/#{SESSION_ID}/message")
      .to_return(status: 200, body: [].to_json,
                 headers: { "Content-Type" => "application/json" })

    reply = @client.stream(SESSION_ID, "ping")
    assert_equal "ack", reply.full_text
  end

  def test_stream_merges_a_multi_assistant_tool_loop_without_duplicate_text
    stub_request(:post, "#{BASE}/session/#{SESSION_ID}/prompt_async")
      .to_return(status: 204, body: "")

    skill_part = {
      id: "p_skill", sessionID: SESSION_ID, messageID: "m_skill",
      type: "tool", tool: "skill", callID: "call_skill",
      state: { status: "completed", input: { name: "travelwolf-itinerary" }, output: "loaded" }
    }
    task_part = {
      id: "p_task", sessionID: SESSION_ID, messageID: "m_task",
      type: "tool", tool: "task", callID: "call_task",
      state: {
        status: "completed",
        input: { subagent_type: "itinerary-planner" },
        output: "{\"days\":[]}",
        metadata: { sessionId: "ses_child" }
      }
    }
    sse = [
      CONNECTED_EVENT,
      {
        type: "todo.updated",
        properties: {
          sessionID: SESSION_ID,
          todos: [ { content: "Plan", status: "in-progress", priority: "high" } ]
        }
      },
      { type: "message.part.updated", properties: { sessionID: SESSION_ID, part: skill_part } },
      { type: "message.part.updated", properties: { sessionID: SESSION_ID, part: task_part } },
      { type: "message.part.delta",
        properties: { sessionID: SESSION_ID, partID: "p_text", field: "text", delta: "SUBAGENT_OK" } },
      { type: "message.part.delta",
        properties: { sessionID: SESSION_ID, partID: "p_text_replay", field: "text", delta: "SUBAGENT_OK" } },
      { type: "session.status", properties: { sessionID: SESSION_ID, status: { type: "idle" } } }
    ].map { |event| "data: #{event.to_json}\n\n" }.join

    stub_request(:get, %r{#{Regexp.escape(BASE)}/event(\?.*)?\z})
      .to_return(status: 200, body: sse,
                 headers: { "Content-Type" => "text/event-stream" })

    exchange = [
      { info: { role: "user" }, parts: [ { type: "text", text: "previous" } ] },
      { info: { role: "assistant" }, parts: [ { type: "text", text: "previous answer" } ] },
      { info: { role: "user" }, parts: [ { type: "text", text: "plan" } ] },
      { info: { role: "assistant" }, parts: [ skill_part ] },
      { info: { role: "assistant" }, parts: [ task_part ] },
      { info: { role: "assistant" }, parts: [ { type: "text", text: "SUBAGENT_OK" } ] }
    ]
    stub_request(:get, "#{BASE}/session/#{SESSION_ID}/message")
      .to_return(status: 200, body: exchange.to_json,
                 headers: { "Content-Type" => "application/json" })

    reply = @client.stream(SESSION_ID, "plan", stream_timeout: 1)

    assert_equal "SUBAGENT_OK", reply.full_text
    assert_equal %w[todowrite skill task], reply.tool_parts.map { |part| part.fetch("tool") }
    assert_equal(
      [ { "content" => "Plan", "status" => "in_progress", "priority" => "high" } ],
      reply.tool_parts.first.dig("input", "todos")
    )
    assert_equal "ses_child", reply.tool_parts.last.dig("metadata", "sessionId")
  end

  def test_write_artifacts_work_in_a_standalone_client
    response = {
      parts: [
        {
          type: "tool",
          tool: "write",
          state: {
            status: "completed",
            input: { filePath: "/tmp/report.md", content: "# Report" }
          }
        }
      ]
    }

    assert_equal(
      [ { filename: "report.md", content: "# Report", content_type: "text/markdown" } ],
      Opencode::ResponseParser.extract_artifact_files(response)
    )
  end

  def test_connection_refused_raises_ConnectionError
    stub_request(:get, "http://opencode.dead/global/health")
      .to_raise(Errno::ECONNREFUSED)

    bad = Opencode::Client.new(base_url: "http://opencode.dead", timeout: 1)
    assert_raises(Opencode::ConnectionError) { bad.health }
  end

  def test_404_on_session_endpoint_raises_SessionNotFoundError
    stub_request(:get, "#{BASE}/session/missing/message")
      .to_return(status: 404, body: { error: "not found" }.to_json,
                 headers: { "Content-Type" => "application/json" })

    assert_raises(Opencode::SessionNotFoundError) do
      @client.get_messages("missing")
    end
  end

  def test_plain_text_404_preserves_SessionNotFoundError
    stub_request(:get, "#{BASE}/session/missing/message")
      .to_return(status: 404, body: "not found", headers: { "Content-Type" => "text/plain" })

    assert_raises(Opencode::SessionNotFoundError) do
      @client.get_messages("missing")
    end
  end

  def test_non_404_client_errors_raise_BadRequestError
    stub_request(:get, "#{BASE}/session")
      .to_return(status: 401, body: { error: "unauthorized" }.to_json,
                 headers: { "Content-Type" => "application/json" })

    assert_raises(Opencode::BadRequestError) { @client.list_sessions }
  end

  def test_plain_text_client_errors_raise_BadRequestError
    stub_request(:get, "#{BASE}/session")
      .to_return(status: 401, body: "unauthorized", headers: { "Content-Type" => "text/plain" })

    assert_raises(Opencode::BadRequestError) { @client.list_sessions }
  end

  def test_non_object_json_client_errors_raise_BadRequestError
    [ '"unauthorized"', "[]", "null" ].each do |body|
      stub_request(:get, "#{BASE}/session")
        .to_return(status: 401, body: body, headers: { "Content-Type" => "application/json" })

      assert_raises(Opencode::BadRequestError) { @client.list_sessions }
    end
  end

  def test_list_questions_uses_the_public_error_hierarchy
    stub_request(:get, "#{BASE}/question")
      .to_return(status: 401, body: { error: "unauthorized" }.to_json,
                 headers: { "Content-Type" => "application/json" })

    assert_raises(Opencode::BadRequestError) { @client.list_questions }
  end

  def test_stream_retries_socket_errors_until_its_timeout
    stub_request(:get, %r{#{Regexp.escape(BASE)}/event(\?.*)?\z})
      .to_raise(SocketError.new("name resolution failed"))

    assert_raises(Opencode::StaleSessionError) do
      @client.stream_events(
        session_id: SESSION_ID,
        timeout: 1,
        first_event_timeout: 0.01
      ) { }
    end
  end

  def test_stream_does_not_swallow_socket_errors_from_the_caller_block
    event = {
      type: "message.part.updated",
      properties: {
        sessionID: SESSION_ID,
        part: { id: "part_1", type: "text", text: "hello" }
      }
    }
    stub_request(:get, %r{#{Regexp.escape(BASE)}/event(\?.*)?\z})
      .to_return(
        status: 200,
        body: "data: #{event.to_json}\n\n",
        headers: { "Content-Type" => "text/event-stream" }
      )

    error = assert_raises(SocketError) do
      Timeout.timeout(0.5) do
        @client.stream_events(session_id: SESSION_ID, timeout: 1, first_event_timeout: 1) do
          raise SocketError, "caller lookup failed"
        end
      end
    end
    assert_equal "caller lookup failed", error.message
  end

  def test_instrumentation_adapter_receives_request_events
    events = []
    Opencode::Instrumentation.adapter = ->(name, payload, &block) {
      events << [ name, payload ]
      block.call
    }

    stub_request(:get, "#{BASE}/global/health")
      .to_return(status: 200, body: "{}",
                 headers: { "Content-Type" => "application/json" })

    @client.health
    assert events.any? { |name, _| name == "opencode.request" },
      "instrumentation adapter must receive opencode.request events"
  end

  def test_instrumentation_does_not_expose_scoped_query_values
    events = []
    Opencode::Instrumentation.adapter = ->(name, payload, &block) {
      events << [ name, payload ]
      block.call
    }
    client = Opencode::Client.new(
      base_url: "#{BASE}?token=base-secret",
      directory: "/private/workspace",
      workspace: "workspace-secret"
    )
    stub_request(:get, %r{#{Regexp.escape(BASE)}/session\?.*})
      .to_return(status: 200, body: "[]",
                 headers: { "Content-Type" => "application/json" })

    client.list_sessions

    payload = events.find { |name, _| name == "opencode.request" }.last
    assert_equal "/session", payload.fetch(:path)
  end

  def test_list_questions_instrumentation_does_not_expose_scoped_query_values
    events = []
    Opencode::Instrumentation.adapter = ->(name, payload, &block) {
      events << [ name, payload ]
      block.call
    }
    client = Opencode::Client.new(
      base_url: "#{BASE}?token=base-secret",
      directory: "/private/workspace",
      workspace: "workspace-secret"
    )
    stub_request(:get, %r{#{Regexp.escape(BASE)}/question\?.*})
      .to_return(status: 200, body: "[]", headers: { "Content-Type" => "application/json" })

    client.list_questions

    payload = events.find { |name, _| name == "opencode.request" }.last
    assert_equal "/question", payload.fetch(:path)
  end

  def test_Reply_distill_returns_typed_Result
    parts = [
      { "type" => "text",     "content" => "hi" },
      { "type" => "text",     "content" => "there" },
      { "type" => "tool",     "tool" => "read", "status" => "completed" }
    ]
    result = Opencode::Reply.distill(parts)

    assert_kind_of Opencode::Reply::Result, result
    assert_equal "hi\n\nthere", result.full_text
    assert_equal 1, result.tool_parts.size
  end

  def test_Instrumentation_no_op_default_yields_block_value
    Opencode::Instrumentation.adapter = nil
    assert_equal 42, Opencode::Instrumentation.instrument("x") { 42 }
  end

  def test_Instrumentation_notify_no_op_without_adapter
    Opencode::Instrumentation.adapter = nil
    # Must not raise; must return nil.
    assert_nil Opencode::Instrumentation.notify("x", foo: 1)
  end

  def test_Instrumentation_notify_forwards_to_adapter_fire_and_forget
    events = []
    Opencode::Instrumentation.adapter = ->(name, payload, &block) {
      # block_given? is misleading inside a lambda — check the captured
      # &block instead. AS::Notifications-shaped adapters always
      # expect a block (it's what marks "event finished").
      events << [ name, payload, !block.nil? ]
      block.call if block
      :adapter_return_ignored
    }

    result = Opencode::Instrumentation.notify("opencode.session.recreated", session_id: "ses_1")

    # notify is fire-and-forget — it returns nil, NOT the adapter's
    # return value (that's what .instrument does).
    assert_nil result
    assert_equal 1, events.size
    name, payload, had_block = events.first
    assert_equal "opencode.session.recreated", name
    assert_equal({ session_id: "ses_1" }, payload)
    assert had_block,
      "notify must still pass an empty block — AS::Notifications-shaped " \
      "adapters always expect one"
  end

  def test_Instrumentation_notify_does_not_require_block
    Opencode::Instrumentation.adapter = ->(_name, _payload, &_block) { }
    # Call site has no block — that's the whole point of notify.
    Opencode::Instrumentation.notify("opencode.test", k: "v")
    # If we got here without raising, the API is fire-and-forget as designed.
    assert true
  end
end
