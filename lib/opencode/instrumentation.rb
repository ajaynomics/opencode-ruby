# frozen_string_literal: true

module Opencode
  # Pluggable instrumentation adapter. opencode-ruby ships zero
  # dependencies on Rails or any specific instrumentation library. Users
  # plug in their own emitter:
  #
  #   # ActiveSupport::Notifications (Rails apps):
  #   Opencode::Instrumentation.adapter = ->(name, payload, &block) {
  #     ActiveSupport::Notifications.instrument(name, payload, &block)
  #   }
  #
  #   # stdout (debugging, non-Rails scripts):
  #   Opencode::Instrumentation.adapter = ->(name, payload, &block) {
  #     puts "[#{name}] #{payload.inspect}"
  #     block.call
  #   }
  #
  # When no adapter is set (default), instrumentation is a no-op pass-
  # through that yields the block and returns its value. The Client emits
  # events for HTTP requests, SSE stream lifecycle, and recovery paths.
  #
  # Event names the Client emits:
  #
  #   - opencode.request       — every HTTP request to OpenCode server
  #
  # If you wire a real adapter, the payload hash carries `:method` and
  # `:path` for opencode.request. Other events may add fields in future
  # versions; treat the payload as forward-compatible.
  #
  # Two emission shapes:
  #
  #   .instrument(name, payload) { ... }  — wrap a block; the duration
  #                                          of the block becomes part
  #                                          of the event (when the
  #                                          adapter is ActiveSupport::
  #                                          Notifications-shaped).
  #
  #   .notify(name, payload)              — fire-and-forget; no block,
  #                                          no duration. Use for
  #                                          point-in-time observations
  #                                          (e.g. "this artifact was
  #                                          dropped").
  module Instrumentation
    class << self
      attr_accessor :adapter
    end

    # Yields the block, optionally routed through the adapter if one is
    # set. Always returns the block's return value (so call sites can
    # wrap their work transparently).
    def self.instrument(name, payload = {})
      return yield unless adapter

      adapter.call(name, payload) { yield }
    end

    # Fire-and-forget event. No block, no return value (the adapter's
    # return is ignored). Use for point-in-time observations where
    # duration doesn't apply — apply_patch.artifacts_dropped,
    # session.recreated, etc.
    #
    # Implementation: invokes the same adapter as #instrument but with
    # an empty block. Hosts that adapt to ActiveSupport::Notifications
    # will see a zero-duration event; hosts that adapt to a structured-
    # event API (Rails.event.notify, OpenTelemetry span events) can
    # detect the empty-block convention if they need to. Most hosts
    # don't need to care.
    def self.notify(name, payload = {})
      return unless adapter

      adapter.call(name, payload) { }
      nil
    end
  end
end
