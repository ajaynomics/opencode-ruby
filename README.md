# opencode-ruby

Idiomatic Ruby client for [OpenCode](https://opencode.ai). Block-form streaming, value-object responses, automatic SSE reconnection.

```ruby
require "opencode-ruby"

client  = Opencode::Client.new(base_url: "http://localhost:4096")
session = client.create_session(title: "My session")

reply = client.stream(session[:id], "Explain monads in two sentences.") do |part|
  print part["content"] if part["type"] == "text"
end

puts
puts reply.full_text
puts "(#{reply.tool_parts.size} tool calls, #{reply.parts_json.size} parts total)"
```

Three lines of setup, four lines of work. Block fires every time a part appears, grows, finalizes, or (for tool calls) advances state. The final return value is a typed `Opencode::Reply::Result` you can persist or inspect.

## Install

```ruby
# Gemfile
gem "opencode-ruby"
```

Or:

```sh
gem install opencode-ruby
```

Then `require "opencode-ruby"`.

## Configuration

```ruby
client = Opencode::Client.new(
  base_url: "http://localhost:4096",   # or ENV["OPENCODE_BASE_URL"]
  password: "secret",                   # or ENV["OPENCODE_SERVER_PASSWORD"]
  timeout:  120                         # or ENV["OPENCODE_TIMEOUT"], seconds
)
```

Multi-tenant apps construct multiple clients with different `base_url`s — each `Opencode::Client` holds its own Net::HTTP connection, no shared state.

## Core API

### Streaming (the headline)

```ruby
reply = client.stream(session_id, "What's 2 + 2?") do |part|
  case part["type"]
  when "text"      then print part["content"]
  when "reasoning" then # ignore, or render in a separate UI
  when "tool"      then puts "  [tool: #{part['tool']} → #{part['status']}]"
  end
end

reply.full_text       # => "2 + 2 = 4."
reply.tool_parts      # => array of terminal tool-call parts
reply.reasoning_text  # => the model's hidden reasoning, if any
reply.parts_json      # => the full ordered parts array, ready for persistence
```

### Synchronous send (no streaming)

```ruby
result = client.send_message(session_id, "Quick yes/no: is Ruby fun?")
# result is the OpenCode response hash; see API docs for fields.
```

### Lower-level event firehose

If you need raw SSE events (every server tick, todo update, prompt asked/replied), use `stream_events` directly:

```ruby
client.stream_events(session_id: session_id) do |event|
  puts event[:type] # "message.part.delta", "todo.updated", "session.idle", ...
end
```

### Interactive prompts

When the agent uses the `question` or `permission` tools, opencode emits `question.asked` / `permission.asked` events. Answer them via:

```ruby
client.reply_question(request_id: "que_...", answers: [["yes"]])
client.reply_permission(request_id: "per_...", reply: "always")
```

## Error model

Every method that hits the network raises `Opencode::Error` (or a subclass) on failure. Catch the parent or the specific subclass:

```ruby
begin
  client.health
rescue Opencode::ConnectionError      # server unreachable
rescue Opencode::TimeoutError         # client-side timeout
rescue Opencode::SessionNotFoundError # 404 on a session
rescue Opencode::StaleSessionError    # session.idle never arrived
rescue Opencode::IdleStreamError      # mid-turn SSE wedge
rescue Opencode::ServerError          # 5xx
rescue Opencode::BadRequestError      # 4xx other than 404
rescue Opencode::Error                # catch-all
end
```

## Instrumentation

Want to see what the gem is doing? Plug in an adapter. Default behaviour is silent no-op — the gem ships zero opinion about your observability stack.

```ruby
# stdout for debugging:
Opencode::Instrumentation.adapter = ->(name, payload, &block) {
  puts "[#{name}] #{payload.inspect}"
  block.call
}

# ActiveSupport::Notifications in a Rails app:
Opencode::Instrumentation.adapter = ->(name, payload, &block) {
  ActiveSupport::Notifications.instrument(name, payload, &block)
}
```

Event names emitted today:

| Event | Payload |
|---|---|
| `opencode.request` | `:method`, `:path` |

## Want this in a Rails app?

See [`examples/conversation_recipe.rb`](examples/conversation_recipe.rb) for a ~60-line plain-ActiveRecord blueprint covering session lifecycle (`with_lock`, `update_columns` mid-stream snapshots, CAS-safe finalize). Drop it into your app and adapt.

If enough Rails developers do that and want it as a one-liner, we'll ship `opencode-rails` with `acts_as_opencode_session`. **File an issue if that's you** — your issue is the signal.

## Position against `opencode_client`

Want every OpenCode endpoint auto-generated from the OpenAPI spec? Use [`opencode_client`](https://rubygems.org/gems/opencode_client). This gem is the hand-rolled idiomatic alternative — smaller surface, opinionated defaults, block-form streaming. Pick whichever fits how you want to write Ruby.

## Compatibility

- Ruby ≥ 3.2
- OpenCode server ≥ 1.15
- Runtime dependency: `activesupport (>= 6.1)` — *not* Rails. ActiveSupport is a standalone helpers gem (`blank?`, `present?`, `presence`, `truncate`, etc.).

## Development

```sh
bundle install
bundle exec rake test
```

12-test smoke covers Client end-to-end against WebMock-stubbed OpenCode endpoints.

## License

MIT. See [LICENSE](LICENSE).
