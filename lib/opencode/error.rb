# frozen_string_literal: true

module Opencode
  class Error < StandardError
    attr_reader :response

    def initialize(message = nil, response: nil)
      @response = response
      super(message)
    end
  end

  class ConnectionError < Error; end
  class TimeoutError < Error; end
  class SessionNotFoundError < Error; end
  class StaleSessionError < Error; end
  # Raised by stream_events when meaningful (non-`server.*`) events stop
  # arriving for longer than the caller's `idle_stream_timeout` window,
  # even though the SSE socket itself is still alive (heartbeats are
  # still flowing). Distinct from StaleSessionError, which fires when
  # the session never produced any events in the first place. This one
  # fires when the session WAS producing events and then went silent —
  # the classic "OpenAI stream wedged mid-turn while the SSE keep-
  # alive ticks on" failure mode.
  class IdleStreamError < Error; end
  class ServerError < Error; end
  class BadRequestError < Error; end
end
