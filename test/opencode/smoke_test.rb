# frozen_string_literal: true

require "test_helper"

# End-to-end smoke test of the gem's public surface. Validates that the
# headline `client.stream(...)` API + Reply::Result + error model + the
# pluggable Instrumentation adapter all work against a fully mocked
# OpenCode server. This is the test we'd point at in the README to
# prove the postcard works.
class SmokeTest < Minitest::Test
  BASE = "http://opencode.test"
  PASSWORD = "test-secret"
  SESSION_ID = "ses_smoke_1"

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
      .to_return(status: 200, body: { id: SESSION_ID, title: "smoke" }.to_json,
                 headers: { "Content-Type" => "application/json" })

    response = @client.create_session(title: "smoke", permissions: [])
    assert_equal SESSION_ID, response[:id]
  end

  def test_send_message_async_returns_empty_body
    stub_request(:post, "#{BASE}/session/#{SESSION_ID}/prompt_async")
      .to_return(status: 204, body: "")

    response = @client.send_message_async(SESSION_ID, "ping")
    assert_equal({}, response)
  end

  def test_stream_returns_typed_Reply_Result_with_full_text
    stub_request(:post, "#{BASE}/session/#{SESSION_ID}/prompt_async")
      .to_return(status: 204, body: "")

    sse = [
      { type: "message.part.delta",
        properties: { sessionID: SESSION_ID, partID: "p1", field: "text", delta: "hello " } },
      { type: "message.part.delta",
        properties: { sessionID: SESSION_ID, partID: "p1", field: "text", delta: "world" } },
      { type: "session.idle", properties: { sessionID: SESSION_ID } }
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

  def test_stream_block_is_optional
    stub_request(:post, "#{BASE}/session/#{SESSION_ID}/prompt_async")
      .to_return(status: 204, body: "")

    sse = [
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
