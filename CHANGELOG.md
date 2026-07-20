# Changelog

## 0.0.1.alpha8 - 2026-07-20

### Fixed

- Parse SSE events with CRLF, CR-only, or LF framing; accept `data:` fields
  with or without the optional leading space; join multiple `data:` fields;
  ignore the stream's optional leading UTF-8 BOM and comment fields; and decode
  correctly when a transport chunk splits any byte of the event framing.

### Changed

- Test Ruby 3.2, 3.3, 3.4, and 4.0; pin every third-party CI and release
  action to an exact reviewed commit; and use Ruby 4.0 for release builds.
- Fail the trusted-publishing job before release when the pushed tag does not
  match `Opencode::VERSION`.

## 0.0.1.alpha7 - 2026-07-18

### Fixed

- Add an at-most-once `on_subscribed` hook to the lower-level
  `Opencode::Client#stream_events` API. Higher-level orchestrators can now
  wait for `server.connected` before submitting `prompt_async` without
  abandoning their own Reply observers, persistence, or recovery pipeline.
- Propagate subscription-hook failures directly and never invoke the hook
  again on SSE reconnect. Ambiguous prompt transport failures therefore
  cannot silently become duplicate turns.

## 0.0.1.alpha6 - 2026-07-18

### Fixed

- Make `Opencode::Client#stream` wait for OpenCode's initial
  `server.connected` SSE readiness frame before submitting `prompt_async`,
  closing the fast-response window where a turn could emit events before the
  client was listening.
- Keep prompt submission at-most-once across automatic SSE reconnects. A
  reconnect now reopens only the event stream; it never posts the user prompt
  again, and prompt transport failures remain visible to the caller.

## 0.0.1.alpha5 - 2026-07-15

### Added

- Extend `Opencode::Client#create_session` with OpenCode's native parent,
  agent, model, metadata, and workspace fields while preserving the existing
  title and permission call shape. Session model strings are encoded with the
  session endpoint's `{ providerID, id }` shape rather than the message
  endpoint's `{ providerID, modelID }` shape.

## 0.0.1.alpha4 - 2026-07-12

### Fixed

- End SSE streams on current OpenCode `session.status` idle events while
  retaining compatibility with legacy `session.idle` events.
- Reconcile every assistant message in the current user turn after multi-step
  tool loops, preserving stream-only parts without duplicating final text.
- Parse terminal tool parts in standalone Ruby clients without relying on the
  Rails-loaded `Object#in?` extension.

## 0.0.1.alpha3 - 2026-07-10

### Added

- `Opencode::Client#update_session` for applying permission rules through
  OpenCode's session PATCH endpoint. OpenCode appends these rules, so hosts
  should fingerprint their ordered policy and call this only when it changes.

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
- OpenCode targeted the then-current 1.15 message-bus shape. This historical
  target was not a blanket SemVer compatibility guarantee; use the README's
  current compatibility evidence for deployment decisions.
- Runtime dependency: `activesupport (>= 6.1)` for `blank?`/`present?`/`presence`/`truncate`/`duplicable?`/`megabytes`. ActiveSupport is *not* Rails — it's a standalone helpers gem.
