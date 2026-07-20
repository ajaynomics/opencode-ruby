# frozen_string_literal: true

# Minimal ActiveSupport surface — `present?`, `blank?`, `presence`,
# `truncate`, `duplicable?`. We deliberately load only the core_ext bits
# we use, not all of activesupport, to keep the boot footprint small in
# non-Rails apps.
require "active_support/core_ext/object/blank"      # provides blank?, present?, presence
require "active_support/core_ext/object/duplicable"
require "active_support/core_ext/hash/keys"         # provides Hash#deep_stringify_keys
require "active_support/core_ext/string/filters"    # provides String#truncate
require "active_support/core_ext/numeric/bytes"     # provides Integer#megabytes
require "marcel"

require_relative "opencode/version"
require_relative "opencode/error"
require_relative "opencode/instrumentation"
require_relative "opencode/response_parser"
require_relative "opencode/part_source"
require_relative "opencode/tool_part"
require_relative "opencode/todo"
require_relative "opencode/prompts"
require_relative "opencode/reply_observer"
require_relative "opencode/reply"
require_relative "opencode/tracer"
require_relative "opencode/client"

module Opencode
end
