# frozen_string_literal: true

module Opencode
  # A namespacing trace emitter.
  #
  # Opencode::Turn emits unprefixed event names like "response.started"
  # and "session.recreated". The host product wraps Turn in a Tracer
  # whose job is to prepend a product prefix and forward to whatever
  # actually emits trace events (typically the host job's
  # `EventTraceable#trace_event`).
  #
  # Two responsibilities live here, and only here:
  #
  #   1. Callable interface: `tracer.call(name, **payload)` — the
  #      contract Turn relies on.
  #   2. Namespacing strategy: prepend "<prefix>." to every event name.
  #
  # A closure-based alternative that mixes both concerns looks like:
  #
  #     tracer: ->(name, **payload) { trace_event("myapp.#{name}", **payload) }
  #
  # That closure conflates the two responsibilities; every caller has
  # to rediscover the prefix-with-period rule, and a typo only shows up
  # in production trace data. Making it a real role removes that risk
  # and makes the rule visible in one place.
  #
  # Usage:
  #
  #   Opencode::Tracer.new(prefix: "myapp", emitter: self)
  #
  # `emitter` must respond to `trace_event(name, **payload)`.
  class Tracer
    def initialize(prefix:, emitter:)
      @prefix = prefix
      @emitter = emitter
    end

    # Tracer is callable so existing call sites that treated the tracer
    # as a lambda (`tracer.call(name, **payload)`) keep working without
    # change. Turn uses this exclusively.
    #
    # Uses `send` because EventTraceable's `trace_event` is a private
    # method of the including class — the convention is "private inside
    # the job, but the substrate's Tracer is allowed to dispatch to it
    # the same way the job's own perform method would."
    def call(name, **payload)
      @emitter.send(:trace_event, "#{@prefix}.#{name}", **payload)
    end
  end
end
