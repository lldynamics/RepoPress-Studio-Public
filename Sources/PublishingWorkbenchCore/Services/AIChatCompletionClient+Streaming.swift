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

private enum AIChatPartialRecoveryStartResult {
  case started
  case unavailable
  case cancelled
  case failed(AIChatCompletionClientError)
}

private let maximumAIChatPartialRecoveryRequestByteCount = 2 * 1_024 * 1_024

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
        var partialRecoveryCount = 0
        var activePrepared = prepared
        var isContinuationAttempt = false
        var generatedContent = ""
        var sawToolCall = false
        var continuationReconciler: AIChatStreamContinuationReconciler?
        var originalPartialError: AIChatCompletionClientError?
        let partialRecoveryPolicy = networkRecoveryPolicy.partialTextRecovery

        while !Task.isCancelled {
          var responseStarted = false
          var receivedHTTP2xx = false
          do {
            let attemptPrepared = activePrepared
            try validatePrepared(attemptPrepared, against: config, apiKey: apiKey)
            let request = try makeURLRequest(
              from: attemptPrepared,
              config: config,
              apiKey: apiKey
            )
            let attemptStartedAt = Date()
            let (lines, response) = try await performWithTimeout(
              seconds: networkRecoveryPolicy.firstByteTimeout,
              timeoutError: .firstByteTimedOut(networkRecoveryPolicy.firstByteTimeout)
            ) {
              try await performPreparedLinesTransport(
                prepared: attemptPrepared,
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
              if !update.toolCallDeltas.isEmpty || !update.toolCalls.isEmpty {
                sawToolCall = true
              }

              var visibleUpdate = update
              if var reconciler = continuationReconciler {
                visibleUpdate.contentDelta = reconciler.reconcile(update.contentDelta)
                continuationReconciler = reconciler
              }
              if !visibleUpdate.contentDelta.isEmpty {
                generatedContent.append(visibleUpdate.contentDelta)
              }
              // Do not manufacture a visible empty update for a swallowed
              // overlap, but preserve finish/usage/tool metadata for callers.
              if !visibleUpdate.contentDelta.isEmpty
                || !visibleUpdate.toolCallDeltas.isEmpty
                || !visibleUpdate.toolCalls.isEmpty
                || visibleUpdate.tokenUsage != nil
                || visibleUpdate.isFinished
              {
                continuation.yield(visibleUpdate)
              }
            }

            // The parser has observed a terminal marker. Flush a short
            // non-overlapping prefix that did not contain a paragraph boundary.
            if var reconciler = continuationReconciler {
              let trailing = reconciler.finish()
              continuationReconciler = reconciler
              if !trailing.isEmpty {
                generatedContent.append(trailing)
                continuation.yield(AIChatStreamUpdate(contentDelta: trailing))
              }
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
            if case .responseTooLarge = normalizedError {
              continuation.finish(throwing: normalizedError)
              return
            }

            if originalPartialError == nil,
              responseStarted || !generatedContent.isEmpty
            {
              originalPartialError = .streamInterruptedAfterPartialContent(
                normalizedError.localizedDescription
              )
            }

            if isPartialTextRecoveryEligible(normalizedError),
              !generatedContent.isEmpty,
              !sawToolCall
            {
              switch startPartialTextRecovery(
                from: prepared,
                config: config,
                apiKey: apiKey,
                generatedContent: generatedContent,
                policy: partialRecoveryPolicy,
                partialRecoveryCount: &partialRecoveryCount,
                reconciler: &continuationReconciler,
                activePrepared: &activePrepared,
                isContinuationAttempt: &isContinuationAttempt
              ) {
              case .started:
                continue
              case .failed(let failure):
                switch failure {
                case .requestContextWindowExceeded, .partialTextRecoveryContextTooLarge:
                  continuation.finish(
                    throwing: AIChatCompletionClientError.streamInterruptedAfterPartialContent(
                      failure.localizedDescription
                    )
                  )
                default:
                  continuation.finish(throwing: failure)
                }
                return
              case .cancelled:
                continuation.finish(throwing: CancellationError())
                return
              case .unavailable:
                break
              }
            }

            if let originalPartialError {
              // Tool calls, incompatible HTTP responses, and authorization
              // failures are terminal for a continuation. Preserve the
              // already-visible content boundary for ordinary interruptions
              // once the bounded recovery policy is exhausted.
              if isContinuationAttempt,
                case .httpStatus = normalizedError
              {
                continuation.finish(throwing: normalizedError)
              } else if case .preparedRequestAuthorizationExpired = normalizedError {
                continuation.finish(throwing: normalizedError)
              } else {
                continuation.finish(throwing: originalPartialError)
              }
              return
            }

            if case .incompleteStream = normalizedError {
              if responseStarted {
                let partialError = AIChatCompletionClientError
                  .streamInterruptedAfterPartialContent(normalizedError.localizedDescription)
                originalPartialError = partialError
                continuation.finish(throwing: partialError)
              } else {
                continuation.finish(throwing: normalizedError)
              }
              return
            }
            if responseStarted {
              let partialError = AIChatCompletionClientError
                .streamInterruptedAfterPartialContent(normalizedError.localizedDescription)
              originalPartialError = partialError
              continuation.finish(throwing: partialError)
              return
            }

            if receivedHTTP2xx {
              continuation.finish(
                throwing: AIChatCompletionClientError.streamInterruptedAfterPartialContent(
                  normalizedError.localizedDescription
                )
              )
              return
            }

            if isContinuationAttempt || !allowsAutomaticReplay(for: prepared.purpose) {
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

  private func isPartialTextRecoveryEligible(
    _ error: AIChatCompletionClientError
  ) -> Bool {
    switch error {
    case .firstByteTimedOut, .resourceTimedOut, .networkFailure, .incompleteStream:
      return true
    default:
      return false
    }
  }

  private func startPartialTextRecovery(
    from prepared: AIPreparedAIChatCompletionRequest,
    config: AIProviderConfig,
    apiKey: String?,
    generatedContent: String,
    policy: AIChatPartialTextRecoveryPolicy,
    partialRecoveryCount: inout Int,
    reconciler: inout AIChatStreamContinuationReconciler?,
    activePrepared: inout AIPreparedAIChatCompletionRequest,
    isContinuationAttempt: inout Bool
  ) -> AIChatPartialRecoveryStartResult {
    guard partialRecoveryCount < policy.maximumRecoveryCount,
      !generatedContent.isEmpty,
      supportsPlainTextPartialRecovery(prepared)
    else {
      return .unavailable
    }

    do {
      try Task.checkCancellation()
      // Revalidate the original authorization/configuration before constructing
      // a second POST. The newly prepared continuation receives the same
      // deadline and is validated again immediately before consume/transport.
      try validatePrepared(activePrepared, against: config, apiKey: apiKey)
      let checkpoint = AIChatStreamContinuationReconciler.checkpointText(
        from: generatedContent,
        maximumCharacterCount: policy.checkpointCharacterCount
      )
      let nextPrepared = try makePartialTextContinuationPrepared(
        from: prepared,
        checkpoint: checkpoint,
        config: config
      )
      guard nextPrepared.encodedBody.count <= maximumAIChatPartialRecoveryRequestByteCount else {
        return .failed(
          .partialTextRecoveryContextTooLarge(
            maximumBytes: maximumAIChatPartialRecoveryRequestByteCount
          )
        )
      }
      try validatePrepared(nextPrepared, against: config, apiKey: apiKey)
      try nextPrepared.consume()
      partialRecoveryCount += 1
      activePrepared = nextPrepared
      isContinuationAttempt = true
      reconciler = AIChatStreamContinuationReconciler(
        alreadyYieldedText: checkpoint,
        overlapProbeCharacterCount: policy.overlapProbeCharacterCount
      )
      return .started
    } catch is CancellationError {
      return .cancelled
    } catch let error as AIChatCompletionClientError {
      return .failed(error)
    } catch {
      return .failed(
        Self.normalizedTransportError(error, policy: networkRecoveryPolicy)
      )
    }
  }

  private func supportsPlainTextPartialRecovery(
    _ prepared: AIPreparedAIChatCompletionRequest
  ) -> Bool {
    guard prepared.purpose == .interactiveChat || prepared.purpose == .utilityTask else {
      return false
    }
    let request = prepared.normalizedRequest
    guard request.tools == nil,
      request.toolChoice == nil,
      request.responseFormat == nil
    else {
      return false
    }
    return !request.messages.contains { message in
      message.role.lowercased() == "tool"
        || message.toolCalls != nil
        || message.toolCallID?.nilIfEmpty != nil
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
