import Foundation

extension AIChatCompletionClient {
  func streamUpdates(
    from lines: AsyncThrowingStream<String, Error>,
    sensitiveValues: [String]
  )
    -> AsyncThrowingStream<AIChatStreamUpdate, Error>
  {
    AsyncThrowingStream { continuation in
      let task = Task(priority: .userInitiated) {
        var dataLines: [String] = []
        var eventByteCount = 0
        var toolCallAccumulator = AIToolCallStreamAccumulator()
        do {
          for try await line in lines {
            try Task.checkCancellation()
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
              try emitSSEEvent(
                dataLines,
                sensitiveValues: sensitiveValues,
                toolCallAccumulator: &toolCallAccumulator,
                continuation: continuation
              )
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
            try emitSSEEvent(
              dataLines,
              sensitiveValues: sensitiveValues,
              toolCallAccumulator: &toolCallAccumulator,
              continuation: continuation
            )
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
    continuation: AsyncThrowingStream<AIChatStreamUpdate, Error>.Continuation
  ) throws {
    guard !dataLines.isEmpty else {
      return
    }

    for payload in normalizedSSEPayloads(from: dataLines) {
      try emitSSEPayload(
        payload,
        sensitiveValues: sensitiveValues,
        toolCallAccumulator: &toolCallAccumulator,
        continuation: continuation
      )
    }
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
    continuation: AsyncThrowingStream<AIChatStreamUpdate, Error>.Continuation
  ) throws {
    let payload = rawPayload.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !payload.isEmpty else {
      return
    }

    if payload == "[DONE]" {
      continuation.yield(
        AIChatStreamUpdate(
          contentDelta: "",
          toolCalls: toolCallAccumulator.toolCalls,
          isFinished: true
        )
      )
      return
    }

    guard let data = payload.data(using: .utf8) else {
      throw AIChatCompletionClientError.invalidResponse
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
        isFinished: decoded.isFinished
      )
    )
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
