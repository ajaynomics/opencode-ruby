# Changelog

## 0.0.1.alpha2 — 2026-05-20

### Added

- `Opencode::Instrumentation.notify(name, payload)` — fire-and-forget
  emission for point-in-time events that don't need duration measurement
  (apply_patch.artifacts_dropped, session.recreated, etc.). Adapter
  receives an empty block so AS::Notifications-shaped sinks see a
  zero-duration event. Complements the existing block-form
  `.instrument(name, payload) { ... }`.

### Why

The block-form `.instrument(name, payload) { }` with an empty block was
awkward at fire-and-forget call sites in opencode-rails. Two named
verbs (`instrument` for wrap-a-block, `notify` for fire-and-forget)
match the host-side mental model and read better at the call site.

## 0.0.1.alpha1 — Unreleased

First public alpha. HTTP + SSE client for OpenCode REST API.

### What's in

- `Opencode::Client` — Net::HTTP-based HTTP client with SSE streaming + automatic reconnection.
  - `#create_session(title:, permissions:)`, `#get_messages(session_id)`, `#list_sessions`, `#delete_session(id)`, `#abort_session(id)`.
  - `#send_message(session_id, text, model:, ...)` — synchronous send-and-poll.
  - `#send_message_async(session_id, text, ...)` — async send.
  - `#stream(session_id, text, ...) { |part| ... } → Opencode::Reply::Result` — **the headline.** Block-form streaming with internal Reply accumulation and final-exchange merge.
  - `#stream_events(session_id:, ...) { |event| ... }` — lower-level SSE event firehose for power users.
  - `#reply_question(request_id:, answers:)` / `#reply_permission(request_id:, reply:)` — answer interactive prompts.
- `Opencode::Reply` — live state machine accumulating SSE events into the assistant's reply. Documented observer protocol (`Opencode::ReplyObserver`).
- `Opencode::Reply::Result` — typed Struct value object returned by `Client#stream` and `Reply#result`. Fields: `:parts_json`, `:full_text`, `:reasoning_text`, `:tool_parts`.
- `Opencode::Instrumentation` — pluggable adapter (default no-op). Plug in `ActiveSupport::Notifications`, OpenTelemetry, stdout, etc.
- `Opencode::ResponseParser`, `Opencode::ToolPart`, `Opencode::PartSource`, `Opencode::Todo` — wire-format helpers used by `Reply` and reusable by callers building their own SSE handling.
- `Opencode::Prompts` — per-Reply registry of pending question/permission prompts (used by `Reply` internally; exposed for callers that need to peek).
- `Opencode::Tracer` — callable that prefixes event names before forwarding to a host emitter.
- Error hierarchy: `Opencode::Error` and seven subclasses (`ConnectionError`, `TimeoutError`, `SessionNotFoundError`, `StaleSessionError`, `IdleStreamError`, `ServerError`, `BadRequestError`).

### What's out

- ActiveRecord-backed session lifecycle, `acts_as_opencode_session`, generators — deferred to `opencode-rails` if external demand materializes. See `examples/conversation_recipe.rb` for the canonical Rails wiring pattern.
- Multi-tenant per-user Docker container orchestration — application glue, not a gem's concern.

### Compatibility

- Ruby ≥ 3.2
- OpenCode server ≥ 1.15 (tested against the message bus schema in `packages/opencode/src/session/message-v2.ts`)
- Runtime dependency: `activesupport (>= 6.1)` for `blank?`/`present?`/`presence`/`truncate`/`duplicable?`/`megabytes`. ActiveSupport is *not* Rails — it's a standalone helpers gem.
