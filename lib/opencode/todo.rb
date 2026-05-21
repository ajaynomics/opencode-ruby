# frozen_string_literal: true

module Opencode
  # One todo item the OpenCode `todowrite` tool and `todo.updated` bus
  # event carry: `content` + `status` + (optional) `priority`.
  # Source-of-truth canonicalization lives here so Reply, ToolDisplay,
  # and any future consumer all share one definition of "what does this
  # todo look like once we've normalized it."
  #
  # Status canonicalization: OpenCode bus events have been observed
  # emitting the hyphenated `"in-progress"` form. The rest of the
  # codebase (per-product views, todowrite tool input shape per the
  # v1.15+ openapi spec) uses the underscored `"in_progress"`.
  # Canonicalize to underscore at every entry point so downstream code
  # never has to handle both.
  module Todo
    HYPHENATED_TO_CANONICAL_STATUS = {
      "in-progress" => "in_progress"
    }.freeze

    module_function

    def canonical_status(status)
      raw = status.to_s
      HYPHENATED_TO_CANONICAL_STATUS.fetch(raw) { raw.tr("-", "_") }
    end

    # Canonicalize one todo hash: string-keyed, normalized status.
    # Returns the input unchanged when it isn't a Hash (the substrate
    # tolerates wire-shape drift defensively).
    def canonicalize(todo)
      return todo unless todo.is_a?(Hash)

      result = todo.deep_stringify_keys
      result["status"] = canonical_status(result["status"]) if result.key?("status")
      result
    end

    def canonicalize_all(todos)
      Array(todos).map { |t| canonicalize(t) }
    end
  end
end
