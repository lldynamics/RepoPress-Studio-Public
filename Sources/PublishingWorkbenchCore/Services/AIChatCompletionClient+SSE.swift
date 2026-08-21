import Foundation

extension AIChatCompletionClient {
  func streamUpdates(
    from lines: AsyncThrowingStream<String, Error>,
    sensitiveValues: [String],
    requiresAnthropicMessageStop: Bool = false
  )
    -> AsyncThrowingStream<AIChatStreamUpdate, Error>
  {
    AsyncThrowingStream { continuation in
      let task = Task(priority: .userInitiated) {
        var dataLines: [String] = []
        var eventByteCount = 0
        var toolCallAccumulator = AIToolCallStreamAccumulator()
        var anthropicState = AnthropicStreamState()
        var observedTerminalMarker = false
        do {
          for try await line in lines {
            try Task.checkCancellation()
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
              observedTerminalMarker =
                try emitSSEEvent(
                  dataLines,
                  sensitiveValues: sensitiveValues,
                  toolCallAccumulator: &toolCallAccumulator,
                  anthropicState: &anthropicState,
                  requiresAnthropicMessageStop: requiresAnthropicMessageStop,
                  continuation: continuation
                ) || observedTerminalMarker
              dataLines.removeAll()
              eventByteCount = 0
              continue
            }
            if trimmed.hasPrefix(":") || trimmed.hasPrefix("event:") {
              continue
            }
            if isRawStreamPayloadLine(trimmed) {
              try validateSSELine(trimmed, currentEventByteCount: &eventByteCount)
              dataLines.append(trimmed)
              continue
            }
            guard trimmed.hasPrefix("data:") else {
              continue
            }

            let payload = trimmed.dropFirst("data:".count)
              .trimmingCharacters(in: .whitespaces)
            let payloadText = String(payload)
            try validateSSELine(payloadText, currentEventByteCount: &eventByteCount)
            dataLines.append(payloadText)
          }

          if !dataLines.isEmpty {
            observedTerminalMarker =
              try emitSSEEvent(
                dataLines,
                sensitiveValues: sensitiveValues,
                toolCallAccumulator: &toolCallAccumulator,
                anthropicState: &anthropicState,
                requiresAnthropicMessageStop: requiresAnthropicMessageStop,
                continuation: continuation
              ) || observedTerminalMarker
          }
          guard observedTerminalMarker else {
            throw AIChatCompletionClientError.incompleteStream
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }

      continuation.onTermination = { _ in
        task.cancel()
      }
    }
  }

  private func emitSSEEvent(
    _ dataLines: [String],
    sensitiveValues: [String],
    toolCallAccumulator: inout AIToolCallStreamAccumulator,
    anthropicState: inout AnthropicStreamState,
    requiresAnthropicMessageStop: Bool,
    continuation: AsyncThrowingStream<AIChatStreamUpdate, Error>.Continuation
  ) throws -> Bool {
    guard !dataLines.isEmpty else {
      return false
    }

    var observedTerminalMarker = false
    for payload in normalizedSSEPayloads(from: dataLines) {
      observedTerminalMarker =
        try emitSSEPayload(
          payload,
          sensitiveValues: sensitiveValues,
          toolCallAccumulator: &toolCallAccumulator,
          anthropicState: &anthropicState,
          requiresAnthropicMessageStop: requiresAnthropicMessageStop,
          continuation: continuation
        ) || observedTerminalMarker
    }
    return observedTerminalMarker
  }

  private func validateSSELine(
    _ line: String,
    currentEventByteCount: inout Int
  ) throws {
    let lineByteCount = line.utf8.count
    guard lineByteCount <= Self.maximumSSEEventByteCount,
      currentEventByteCount <= Self.maximumSSEEventByteCount - lineByteCount
    else {
      throw AIChatCompletionClientError.responseTooLarge(
        maximumBytes: Self.maximumSSEEventByteCount
      )
    }
    currentEventByteCount += lineByteCount
  }

  private func emitSSEPayload(
    _ rawPayload: String,
    sensitiveValues: [String],
    toolCallAccumulator: inout AIToolCallStreamAccumulator,
    anthropicState: inout AnthropicStreamState,
    requiresAnthropicMessageStop: Bool,
    continuation: AsyncThrowingStream<AIChatStreamUpdate, Error>.Continuation
  ) throws -> Bool {
    let payload = rawPayload.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !payload.isEmpty else {
      return false
    }

    if payload == "[DONE]" {
      guard !requiresAnthropicMessageStop else { return false }
      continuation.yield(
        AIChatStreamUpdate(
          contentDelta: "",
          toolCalls: toolCallAccumulator.toolCalls,
          isFinished: true
        )
      )
      return true
    }

    guard let data = payload.data(using: .utf8) else {
      throw AIChatCompletionClientError.invalidResponse
    }

    if requiresAnthropicMessageStop {
      // Native Anthropic streams are JSON event envelopes.  Keep accepting
      // future event types without interpreting them as OpenAI chunks, while
      // still rejecting malformed envelopes and waiting for message_stop.
      guard let eventType = anthropicEventType(from: data) else {
        throw AIChatCompletionClientError.invalidResponse
      }
      guard isAnthropicStreamEventType(eventType) else {
        return false
      }
      return try emitAnthropicSSEPayload(
        data,
        sensitiveValues: sensitiveValues,
        state: &anthropicState,
        continuation: continuation
      )
    }

    if let eventType = anthropicEventType(from: data),
      isAnthropicStreamEventType(eventType)
    {
      return try emitAnthropicSSEPayload(
        data,
        sensitiveValues: sensitiveValues,
        state: &anthropicState,
        continuation: continuation
      )
    }

    let decoded = try decoder.decode(AIChatCompletionStreamChunk.self, from: data)
    if let errorMessage = decoded.error?.displayMessage.nilIfEmpty {
      let sanitizedMessage = HTTPErrorResponseSanitizer.sanitize(
        text: errorMessage,
        sensitiveValues: sensitiveValues
      )
      throw AIChatCompletionClientError.httpStatus(
        200,
        sanitizedMessage,
        retryAfterSeconds: nil
      )
    }

    let content = decoded.contentDelta
    let toolCallDeltas = decoded.toolCallDeltas
    toolCallAccumulator.append(toolCallDeltas)
    // Yield an empty update for a valid SSE event even when it contains only
    // reasoning/role metadata. The caller uses this as a no-replay boundary;
    // such metadata is still never exposed through contentDelta.
    continuation.yield(
      AIChatStreamUpdate(
        contentDelta: content,
        toolCallDeltas: toolCallDeltas,
        toolCalls: toolCallAccumulator.toolCalls,
        tokenUsage: decoded.usage?.tokenUsage,
        isFinished: requiresAnthropicMessageStop ? false : decoded.isFinished
      )
    )
    return requiresAnthropicMessageStop ? false : decoded.isFinished
  }

  private func emitAnthropicSSEPayload(
    _ data: Data,
    sensitiveValues: [String],
    state: inout AnthropicStreamState,
    continuation: AsyncThrowingStream<AIChatStreamUpdate, Error>.Continuation
  ) throws -> Bool {
    let decoded = try decoder.decode(AnthropicStreamPayload.self, from: data)
    switch decoded.type {
    case "ping":
      // A provider heartbeat is deliberately not exposed as an update.  This
      // keeps it outside both the first-byte and no-replay content boundaries.
      return false

    case "error":
      let message = HTTPErrorResponseSanitizer.sanitize(
        text: decoded.error?.message ?? "Anthropic stream error",
        sensitiveValues: sensitiveValues
      )
      throw AIChatCompletionClientError.httpStatus(
        200,
        message,
        retryAfterSeconds: nil
      )

    case "message_start":
      state.apply(usage: decoded.message?.usage)
      continuation.yield(
        AIChatStreamUpdate(
          contentDelta: "",
          toolCalls: state.toolCalls,
          tokenUsage: state.tokenUsage
        )
      )
      return false

    case "content_block_start":
      let index = decoded.index ?? 0
      let block = decoded.contentBlock
      let toolDelta: AIToolCallDelta?
      if block?.type == "tool_use" {
        if let input = block?.input {
          guard case .object = input else {
            throw AIChatCompletionClientError.invalidResponse
          }
        }
        toolDelta = state.startTool(
          index: index,
          id: block?.id,
          name: block?.name
        )
      } else {
        toolDelta = nil
      }
      continuation.yield(
        AIChatStreamUpdate(
          contentDelta: "",
          toolCallDeltas: toolDelta.map { [$0] } ?? [],
          toolCalls: state.toolCalls,
          tokenUsage: state.tokenUsage
        )
      )
      return false

    case "content_block_delta":
      let index = decoded.index ?? 0
      let delta = decoded.delta
      var content = ""
      var toolDeltas: [AIToolCallDelta] = []
      switch delta?.type {
      case "text_delta":
        content = delta?.text ?? ""
      case "input_json_delta":
        if let toolDelta = state.appendToolInput(
          index: index,
          partialJSON: delta?.partialJSON
        ) {
          toolDeltas = [toolDelta]
        }
      default:
        break
      }
      continuation.yield(
        AIChatStreamUpdate(
          contentDelta: content,
          toolCallDeltas: toolDeltas,
          toolCalls: state.toolCalls,
          tokenUsage: state.tokenUsage
        )
      )
      return false

    case "content_block_stop":
      try state.validateToolInput(at: decoded.index ?? 0)
      continuation.yield(
        AIChatStreamUpdate(
          contentDelta: "",
          toolCalls: state.toolCalls,
          tokenUsage: state.tokenUsage
        )
      )
      return false

    case "message_delta":
      state.apply(usage: decoded.usage)
      // `stop_reason` is informational here.  Native Anthropic streams are
      // complete only after the explicit message_stop event.
      continuation.yield(
        AIChatStreamUpdate(
          contentDelta: "",
          toolCalls: state.toolCalls,
          tokenUsage: state.tokenUsage
        )
      )
      return false

    case "message_stop":
      try state.validateToolInputs()
      continuation.yield(
        AIChatStreamUpdate(
          contentDelta: "",
          toolCalls: state.toolCalls,
          tokenUsage: state.tokenUsage,
          isFinished: true
        )
      )
      return true

    default:
      return false
    }
  }

  private func normalizedSSEPayloads(from dataLines: [String]) -> [String] {
    let payload = dataLines.joined(separator: "\n")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !payload.isEmpty else {
      return []
    }
    if payload == "[DONE]" || isSingleJSONPayload(payload) {
      return [payload]
    }

    let splitPayloads =
      dataLines
      .flatMap { $0.components(separatedBy: .newlines) }
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    return splitPayloads.isEmpty ? [payload] : splitPayloads
  }

  private func isSingleJSONPayload(_ payload: String) -> Bool {
    guard let data = payload.data(using: .utf8) else {
      return false
    }
    return (try? JSONSerialization.jsonObject(with: data)) != nil
  }

  private func isRawStreamPayloadLine(_ line: String) -> Bool {
    line == "[DONE]" || line.hasPrefix("{") || line.hasPrefix("[")
  }

  func responseBody(from lines: AsyncThrowingStream<String, Error>) async throws -> String {
    var body = ""
    for try await line in lines {
      try Task.checkCancellation()
      let remainingCount = HTTPErrorResponseSanitizer.maximumCharacterCount - body.count
      guard remainingCount > 0 else { break }
      if !body.isEmpty {
        body.append("\n")
      }
      body.append(contentsOf: line.prefix(remainingCount))
      if line.count > remainingCount
        || body.count >= HTTPErrorResponseSanitizer.maximumCharacterCount
      {
        body.append("\n[远端响应已截断]")
        break
      }
    }
    return body
  }
}
