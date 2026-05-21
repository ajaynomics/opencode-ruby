# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "opencode-ruby"
require "minitest/autorun"
require "webmock/minitest"

# Tests run against WebMock-stubbed endpoints; never hit the network.
WebMock.disable_net_connect!
