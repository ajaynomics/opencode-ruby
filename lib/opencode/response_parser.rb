# frozen_string_literal: true

module Opencode
  module ResponseParser
    def self.extract_text(response_body)
      parts = response_body[:parts] || []
      parts
        .select { |p| p[:type] == "text" }
        .map { |p| p[:text] }
        .join("\n\n")
    end

    def self.extract_reasoning(response_body)
      parts = response_body[:parts] || []
      reasoning = parts
        .select { |p| p[:type] == "reasoning" }
        .map { |p| p[:text] }
        .join("\n\n")
      reasoning.presence
    end

    TERMINAL_STATUSES = %w[completed error].freeze

    # Terminal-only tool list. Returned as canonical string-keyed hashes
    # (same shape `extract_interleaved_parts` returns) so callers do not
    # have to know which path produced the data.
    def self.extract_tool_summary(response_body)
      parts = response_body[:parts] || []
      parts
        .select { |p| p[:type] == "tool" && TERMINAL_STATUSES.include?(p.dig(:state, :status)) }
        .map { |p| build_tool_summary(p) }
    end

    def self.extract_interleaved_parts(response_body)
      parts = response_body[:parts] || []

      parts.filter_map do |part|
        case part[:type]
        when "text"
          { "type" => "text", "content" => part[:text] }
        when "reasoning"
          { "type" => "reasoning", "content" => part[:text] }
        when "tool"
          status = part.dig(:state, :status)
          next unless TERMINAL_STATUSES.include?(status)

          build_tool_summary(part)
        else
          nil
        end
      end
    end

    # Canonical tool-part shape from one OpenCode message part. Delegates
    # to Opencode::ToolPart so the streaming path (Reply#apply_tool_state)
    # and recovery path (this method) cannot drift.
    def self.build_tool_summary(part)
      Opencode::ToolPart.from_message_part(part)
    end

    private_class_method :build_tool_summary

    def self.extract_tokens(response_body)
      response_body.dig(:info, :tokens)
    end

    def self.extract_cost(response_body)
      response_body.dig(:info, :cost)
    end

    def self.extract_cache_tokens(response_body)
      tokens = response_body.dig(:info, :tokens) || {}
      {
        cache_read: tokens.dig(:cache, :read) || 0,
        cache_write: tokens.dig(:cache, :write) || 0
      }
    end

    def self.extract_error(response_body)
      error = response_body.dig(:info, :error)
      return nil unless error.is_a?(Hash)

      {
        name: error[:name],
        message: error.dig(:data, :message),
        status_code: error.dig(:data, :statusCode),
        retryable: error.dig(:data, :isRetryable),
        url: error.dig(:data, :metadata, :url)
      }.compact
    end

    MAX_ARTIFACT_SIZE = 10.megabytes
    ARTIFACT_TOOLS = %w[write apply_patch].freeze

    def self.extract_artifact_files(response_body)
      parts = response_body[:parts] || []
      completed_tools = parts.select do |p|
        p[:type] == "tool" &&
          ARTIFACT_TOOLS.include?(p[:tool]) &&
          p.dig(:state, :status) == "completed"
      end
      return [] if completed_tools.empty?

      files = completed_tools.flat_map { |part| extract_files_from_tool_part(part) }
      files.uniq { |f| f[:filename] }
    end

    def self.extract_artifacts_from_messages(messages)
      return [] unless messages.is_a?(Array)

      messages
        .select { |m| m.dig(:info, :role) == "assistant" }
        .flat_map { |m| extract_artifact_files(m) }
        .uniq { |f| f[:filename] }
    end

    def self.extract_files_from_tool_part(part)
      case part[:tool]
      when "write"
        extract_from_write(part)
      when "apply_patch"
        extract_from_apply_patch(part)
      else
        []
      end
    end

    def self.extract_from_write(part)
      content = part.dig(:state, :input, :content)
      file_path = part.dig(:state, :input, :filePath)
      return [] if content.blank? || file_path.blank?
      return [] if content.bytesize > MAX_ARTIFACT_SIZE

      filename = File.basename(file_path)
      content_type = Marcel::MimeType.for(extension: File.extname(filename))
      [ { filename: filename, content: content, content_type: content_type } ]
    end

    # apply_patch tool metadata shape changed materially between the early
    # opencode versions this code originally targeted (which exposed
    # `before` + `after` post-write file content as inline strings) and
    # v1.4.0+ (which dropped them and only exposes the diff text in `patch`
    # plus a `files` array of { filePath, relativePath, type, patch,
    # additions, deletions, movePath? } descriptors). Source of truth:
    # https://raw.githubusercontent.com/anomalyco/opencode/v1.15.0/packages/opencode/src/tool/apply_patch.ts
    #
    # With no `after` field in the v1.15.0 wire shape, this method previously
    # silently returned [] for every real apply_patch invocation while still
    # passing its (now-stale-shape) unit test — the worst kind of bug: a
    # green test paired with a dead production path.
    #
    # Current behavior (intentional, until apply_patch becomes a hot path
    # for the gem's users): we accept the v1.15.0 shape and return []. Most
    # agents write whole files via the `write` tool rather than patching,
    # so the practical impact today is zero. When you do use apply_patch,
    # opencode-rails' `Opencode::Exchange#tool_artifacts` emits
    # `opencode.apply_patch.artifacts_dropped` so operators see the silent
    # drop and can route through the missing sandbox-read path.
    #
    # The event emission lives on Exchange (not here) because ResponseParser
    # is a pure module — every other method takes a hash and returns a hash.
    # Pure functions stay pure.
    def self.extract_from_apply_patch(_part)
      []
    end

    private_class_method :extract_files_from_tool_part, :extract_from_write, :extract_from_apply_patch
  end
end
