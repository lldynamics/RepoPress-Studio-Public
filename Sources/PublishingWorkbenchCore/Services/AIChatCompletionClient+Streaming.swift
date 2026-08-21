import Foundation

private struct AIChatSendableError: Sendable {
  let value: AIChatCompletionClientError
}

private enum AIChatLineEvent: Sendable {
  case line(String)
  case finished
  case cancelled
  case failed(AIChatSendableError)
  case firstByteTimedOut
  case resourceTimedOut
}

extension AIChatCompletionClient {
  public func stream(
    request completionRequest: AIChatCompletionRequest,
    config: AIProviderConfig,
    apiKey: String?,
    purpose: AIProviderRequestPurpose = .interactiveChat
  ) async throws -> AsyncThrowingStream<AIChatStreamUpdate, Error> {
    // Validate endpoint policy first so an insecure credential URL is rejected
    // consistently even when the capability gate would also fail closed.
    _ = try validatedRequestURL(config: config, apiKey: apiKey)
    guard
      purpose == .capabilityProbe
        || config.capabilitySupport(for: .streamingResponse) == .supported
    else {
      throw AIChatCompletionClientError.streamingUnsupported
    }
    let prepared = try prepareRequest(
      completionRequest,
      config: config,
      purpose: purpose,
      mode: .streaming
    )
    return try await streamPrepared(
      prepared,
      config: config,
      apiKey: apiKey
    )
  }

  public func streamPrepared(
    _ prepared: AIPreparedAIChatCompletionRequest,
    config: AIProviderConfig,
    apiKey: String?
  ) async throws -> AsyncThrowingStream<AIChatStreamUpdate, Error> {
    guard prepared.mode == .streaming else {
      throw AIChatCompletionClientError.preparedRequestModeMismatch
    }
    guard
      prepared.purpose == .capabilityProbe
        || config.capabilitySupport(for: .streamingResponse) == .supported
    else {
      throw AIChatCompletionClientError.streamingUnsupported
    }
    try validatePrepared(prepared, against: config, apiKey: apiKey)
    try prepared.consume()

    if config.usesCodexAppServer {
      return codexAppServerStream(prepared: prepared, config: config)
    }

    let selectedTransport = try transport(for: config)
    guard let streamingTransport = selectedTransport as? AIChatStreamingTransport else {
      throw AIChatCompletionClientError.streamingUnsupported
    }

    let nonStreamingFallbackPrepared = try makeNonStreamingVariant(
      from: prepared,
      config: config
    )

    return recoveredStreamUpdates(
      prepared: prepared,
      nonStreamingFallbackPrepared: nonStreamingFallbackPrepared,
      config: config,
      apiKey: apiKey,
      transport: streamingTransport,
      sensitiveValues: [apiKey].compactMap { $0 }
    )
  }

  private func codexAppServerStream(
    prepared: AIPreparedAIChatCompletionRequest,
    config: AIProviderConfig
  ) -> AsyncThrowingStream<AIChatStreamUpdate, Error> {
    AsyncThrowingStream { continuation in
      let task = Task(priority: .userInitiated) {
        do {
          let result = try await completeWithCodexAppServer(
            prepared: prepared,
            config: config
          )
          try Task.checkCancellation()
          continuation.yield(
            AIChatStreamUpdate(
              contentDelta: result.content,
              tokenUsage: result.tokenUsage,
              isFinished: true
            )
          )
          continuation.finish()
        } catch is CancellationError {
          continuation.finish(throwing: CodexAppServerError.cancelled)
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { @Sendable _ in
        task.cancel()
      }
    }
  }

  private func recoveredStreamUpdates(
    prepared: AIPreparedAIChatCompletionRequest,
    nonStreamingFallbackPrepared: AIPreparedAIChatCompletionRequest,
    config: AIProviderConfig,
    apiKey: String?,
    transport: AIChatStreamingTransport,
    sensitiveValues: [String]
  ) -> AsyncThrowingStream<AIChatStreamUpdate, Error> {
    return AsyncThrowingStream { continuation in
      let task = Task(priority: .userInitiated) {
        var completedRetryCount = 0
        var compatibilityFallbackCount = 0

        while !Task.isCancelled {
          var responseStarted = false
          var receivedHTTP2xx = false
          do {
            try validatePrepared(prepared, against: config, apiKey: apiKey)
            let request = try makeURLRequest(
              from: prepared,
              config: config,
              apiKey: apiKey
            )
            let attemptStartedAt = Date()
            let (lines, response) = try await performWithTimeout(
              seconds: networkRecoveryPolicy.firstByteTimeout,
              timeoutError: .firstByteTimedOut(networkRecoveryPolicy.firstByteTimeout)
            ) {
              try await performPreparedLinesTransport(
                prepared: prepared,
                config: config,
                apiKey: apiKey,
                request: request,
                transport: transport
              )
            }
            guard let httpResponse = response as? HTTPURLResponse else {
              throw AIChatCompletionClientError.invalidResponse
            }

            let boundedLines = timedLines(
              from: lines,
              firstByteTimeout: remainingTimeout(
                networkRecoveryPolicy.firstByteTimeout,
                since: attemptStartedAt
              ),
              resourceTimeout: remainingTimeout(
                networkRecoveryPolicy.resourceTimeout,
                since: attemptStartedAt
              )
            )
            guard (200..<300).contains(httpResponse.statusCode) else {
              let body = HTTPErrorResponseSanitizer.sanitize(
                text: try await responseBody(from: boundedLines),
                sensitiveValues: sensitiveValues
              )
              throw httpError(statusResponse: httpResponse, body: body)
            }
            receivedHTTP2xx = true

            let updates = streamUpdates(
              from: boundedLines,
              sensitiveValues: sensitiveValues,
              requiresAnthropicMessageStop: config.usesAnthropicAPI
            )
            for try await update in updates {
              try Task.checkCancellation()
              // Any successfully decoded SSE update means the remote service
              // has accepted and started processing this request. Preserve the
              // no-replay boundary even for role/reasoning-only metadata;
              // heartbeat/comment/blank lines never become updates.
              responseStarted = true
              continuation.yield(update)
            }
            continuation.finish()
            return
          } catch is CancellationError {
            continuation.finish(throwing: CancellationError())
            return
          } catch {
            if Task.isCancelled {
              continuation.finish(throwing: CancellationError())
              return
            }
            let normalizedError = Self.normalizedTransportError(
              error,
              policy: networkRecoveryPolicy
            )
            if case .incompleteStream = normalizedError {
              if responseStarted {
                continuation.finish(
                  throwing: AIChatCompletionClientError.streamInterruptedAfterPartialContent(
                    normalizedError.localizedDescription
                  )
                )
              } else {
                continuation.finish(throwing: normalizedError)
              }
              return
            }
            if responseStarted {
              continuation.finish(
                throwing: AIChatCompletionClientError.streamInterruptedAfterPartialContent(
                  normalizedError.localizedDescription
                )
              )
              return
            }

            if receivedHTTP2xx {
              if case .responseTooLarge = normalizedError {
                continuation.finish(throwing: normalizedError)
                return
              }
              continuation.finish(
                throwing: AIChatCompletionClientError.streamInterruptedAfterPartialContent(
                  normalizedError.localizedDescription
                )
              )
              return
            }

            if !allowsAutomaticReplay(for: prepared.purpose) {
              // An interactive authorization allows one POST attempt. A
              // transport-level retry would be a second remote attempt that
              // bypasses the request safety gate, even before any SSE content is
              // observed. Let the store expose its existing manual-retry path.
              continuation.finish(throwing: normalizedError)
              return
            }

            if prepared.purpose == .connectionTest,
              compatibilityFallbackCount == 0,
              Self.isExplicitStreamCapabilityRejection(normalizedError)
            {
              compatibilityFallbackCount += 1
              do {
                try validatePrepared(
                  nonStreamingFallbackPrepared,
                  against: config,
                  apiKey: apiKey
                )
                try nonStreamingFallbackPrepared.consume()
                let fallbackResult = try await sendCompletePrepared(
                  prepared: nonStreamingFallbackPrepared,
                  config: config,
                  apiKey: apiKey,
                )
                try Task.checkCancellation()
                continuation.yield(
                  AIChatStreamUpdate(
                    contentDelta: fallbackResult.content,
                    toolCalls: fallbackResult.toolCalls,
                    tokenUsage: fallbackResult.tokenUsage,
                    isFinished: true
                  )
                )
                continuation.finish()
              } catch is CancellationError {
                continuation.finish(throwing: CancellationError())
              } catch {
                continuation.finish(
                  throwing: Self.normalizedTransportError(
                    error,
                    policy: networkRecoveryPolicy
                  ))
              }
              return
            }

            guard
              shouldAutomaticallyRetry(
                normalizedError,
                completedRetryCount: completedRetryCount
              )
            else {
              continuation.finish(throwing: normalizedError)
              return
            }

            let delay = automaticRetryDelay(
              for: normalizedError,
              completedRetryCount: completedRetryCount
            )
            completedRetryCount += 1
            do {
              try await sleep(seconds: delay)
            } catch {
              continuation.finish(throwing: CancellationError())
              return
            }
          }
        }

        continuation.finish(throwing: CancellationError())
      }

      continuation.onTermination = { _ in
        task.cancel()
      }
    }
  }

  private func performPreparedLinesTransport(
    prepared: AIPreparedAIChatCompletionRequest,
    config: AIProviderConfig,
    apiKey: String?,
    request: URLRequest,
    transport: AIChatStreamingTransport
  ) async throws -> (AsyncThrowingStream<String, Error>, URLResponse) {
    // Keep authorization expiry fail-closed at the actual network boundary, not
    // only at the beginning of this retry loop.
    try validatePrepared(prepared, against: config, apiKey: apiKey)
    return try await transport.lines(for: request)
  }

  private func timedLines(
    from lines: AsyncThrowingStream<String, Error>,
    firstByteTimeout: TimeInterval,
    resourceTimeout: TimeInterval
  ) -> AsyncThrowingStream<String, Error> {
    let recoveryPolicy = networkRecoveryPolicy
    return AsyncThrowingStream { continuation in
      let (events, eventContinuation) = AsyncStream<AIChatLineEvent>.makeStream()
      let sourceTask = Task(priority: .userInitiated) {
        do {
          var cumulativeByteCount = 0
          for try await line in lines {
            try Task.checkCancellation()
            let lineByteCount = line.utf8.count
            guard lineByteCount <= URLSessionAIChatTransport.maximumStreamingLineByteCount,
              cumulativeByteCount <= URLSessionAIChatTransport.maximumStreamingResponseByteCount
                - lineByteCount
            else {
              throw AIChatCompletionClientError.responseTooLarge(
                maximumBytes: URLSessionAIChatTransport.maximumStreamingResponseByteCount
              )
            }
            cumulativeByteCount += lineByteCount
            eventContinuation.yield(.line(line))
          }
          eventContinuation.yield(.finished)
        } catch is CancellationError {
          eventContinuation.yield(.cancelled)
        } catch {
          eventContinuation.yield(
            .failed(
              AIChatSendableError(
                value: Self.normalizedTransportError(error, policy: recoveryPolicy)
              )
            )
          )
        }
      }
      let firstByteTimeoutTask = Task {
        do {
          try await sleep(seconds: firstByteTimeout)
          eventContinuation.yield(.firstByteTimedOut)
        } catch {
          // Cancellation means a line or terminal event won the race.
        }
      }
      let resourceTimeoutTask = Task {
        do {
          try await sleep(seconds: resourceTimeout)
          eventContinuation.yield(.resourceTimedOut)
        } catch {
          // Cancellation means the stream completed before its resource limit.
        }
      }
      let coordinatorTask = Task(priority: .userInitiated) {
        var receivedFirstDataLine = false
        defer {
          sourceTask.cancel()
          firstByteTimeoutTask.cancel()
          resourceTimeoutTask.cancel()
          eventContinuation.finish()
        }

        for await event in events {
          guard !Task.isCancelled else { break }
          switch event {
          case .line(let line):
            if !receivedFirstDataLine, Self.isSSEDataBearingLine(line) {
              receivedFirstDataLine = true
              firstByteTimeoutTask.cancel()
            }
            continuation.yield(line)
          case .finished:
            continuation.finish()
            return
          case .cancelled:
            continuation.finish(throwing: CancellationError())
            return
          case .failed(let error):
            continuation.finish(throwing: error.value)
            return
          case .firstByteTimedOut:
            guard !receivedFirstDataLine else { continue }
            continuation.finish(
              throwing: AIChatCompletionClientError.firstByteTimedOut(firstByteTimeout)
            )
            return
          case .resourceTimedOut:
            continuation.finish(
              throwing: AIChatCompletionClientError.resourceTimedOut(resourceTimeout)
            )
            return
          }
        }
      }

      continuation.onTermination = { _ in
        coordinatorTask.cancel()
        sourceTask.cancel()
        firstByteTimeoutTask.cancel()
        resourceTimeoutTask.cancel()
        eventContinuation.finish()
      }
    }
  }

  private static func isSSEDataBearingLine(_ line: String) -> Bool {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty,
      !trimmed.hasPrefix(":"),
      !trimmed.hasPrefix("event:")
    else {
      return false
    }
    if trimmed.hasPrefix("data:") {
      let payload = trimmed.dropFirst("data:".count)
        .trimmingCharacters(in: .whitespaces)
      guard !payload.isEmpty else { return false }
      if let data = payload.data(using: .utf8),
        anthropicEventType(from: data) == "ping"
      {
        return false
      }
      return true
    }
    if let data = trimmed.data(using: .utf8),
      anthropicEventType(from: data) == "ping"
    {
      return false
    }
    return trimmed == "[DONE]" || trimmed.hasPrefix("{") || trimmed.hasPrefix("[")
  }

  func performWithTimeout<Value: Sendable>(
    seconds: TimeInterval,
    timeoutError: AIChatCompletionClientError,
    operation: @escaping @Sendable () async throws -> Value
  ) async throws -> Value {
    try await withThrowingTaskGroup(of: Value.self) { group in
      group.addTask(operation: operation)
      group.addTask {
        try await sleep(seconds: seconds)
        throw timeoutError
      }
      defer { group.cancelAll() }
      guard let result = try await group.next() else {
        throw CancellationError()
      }
      return result
    }
  }

  func sleep(seconds: TimeInterval) async throws {
    guard seconds > 0 else {
      try Task.checkCancellation()
      return
    }
    let nanoseconds = UInt64(min(seconds * 1_000_000_000, Double(UInt64.max)))
    try await Task.sleep(nanoseconds: nanoseconds)
  }

  private func remainingTimeout(
    _ timeout: TimeInterval,
    since startDate: Date
  ) -> TimeInterval {
    max(0.001, timeout - Date().timeIntervalSince(startDate))
  }

  static func normalizedTransportError(
    _ error: Error,
    policy: AIChatNetworkRecoveryPolicy
  ) -> AIChatCompletionClientError {
    if let clientError = error as? AIChatCompletionClientError {
      return clientError
    }
    if error is DecodingError {
      return .invalidResponse
    }
    if let responseLimitError = error as? HTTPResponseLimitError {
      return .responseTooLarge(maximumBytes: responseLimitError.maximumByteCount)
    }
    if let urlError = error as? URLError {
      if urlError.code == .timedOut {
        return .resourceTimedOut(policy.resourceTimeout)
      }
      return .networkFailure(urlError.localizedDescription)
    }
    return .networkFailure(error.localizedDescription)
  }

  private static func isExplicitStreamCapabilityRejection(
    _ error: AIChatCompletionClientError
  ) -> Bool {
    guard case .httpStatus(let status, let body, _) = error,
      [400, 404, 405, 422].contains(status)
    else {
      return false
    }
    return AIProviderCapabilityRejectionClassifier.explicitlyRejects(
      body,
      capability: .streamingResponse
    )
  }

  func shouldAutomaticallyRetry(
    _ error: AIChatCompletionClientError,
    completedRetryCount: Int
  ) -> Bool {
    guard completedRetryCount < networkRecoveryPolicy.maximumAutomaticRetryCount,
      error.isAutomaticallyRetryable
    else {
      return false
    }
    if let retryAfter = error.retryAfterSeconds {
      return retryAfter <= networkRecoveryPolicy.maximumAutomaticRetryAfterDelay
    }
    return true
  }

  func automaticRetryDelay(
    for error: AIChatCompletionClientError,
    completedRetryCount: Int
  ) -> TimeInterval {
    if let retryAfter = error.retryAfterSeconds {
      return retryAfter
    }
    return networkRecoveryPolicy.automaticRetryBaseDelay
      * pow(2, Double(completedRetryCount))
  }
}
