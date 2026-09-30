import Foundation
import XCTest

@testable import PublishingAICore

final class AIChatStreamRecoveryTests: XCTestCase {
  func testNonStreamingAuthorizationDeadlineRecheckedAfterOutboundHook() async throws {
    let clock = AIChatRequestTestClock()
    let transport = AIChatBoundaryCompleteTransport()
    var client = AIChatCompletionClient(transport: transport)
      .authorizingNonStreamingRequests { clock.advance(by: 60) }
    client.requestValidationDate = { clock.now() }
    let prepared = try client.prepareRequest(
      AIChatCompletionRequest(
        model: "model", messages: [AIChatMessage(role: "user", content: "Hello")]
      ), config: localConfig, purpose: .interactiveChat, mode: .nonStreaming
    ).bindingAuthorizationDeadline(clock.now().addingTimeInterval(60))
    await XCTAssertThrowsErrorAsync(
      try await client.completePrepared(prepared, config: localConfig, apiKey: nil)
    ) { error in
      XCTAssertEqual(error as? AIChatCompletionClientError, .preparedRequestAuthorizationExpired)
    }
    let count = await transport.requestCount
    XCTAssertEqual(count, 0)
  }

  func testRevocationAfterAuthorizationCancelsBeforeTransportDispatch() async throws {
    let transport = InterruptibleAIChatStreamingTransport(pausesBeforeSending: true)
    let cancellation = AIChatStreamingRequestCancellation()
    var client = AIChatCompletionClient(transport: transport)
      .authorizingStreamingRequests {}
    client.streamingRequestCancellation = cancellation
    let stream = try await client.stream(
      request: AIChatCompletionRequest(
        model: "model", messages: [AIChatMessage(role: "user", content: "Hello")]
      ),
      config: localConfig, apiKey: nil
    )
    try await transport.waitForFirstRequest()
    cancellation.cancel()
    await transport.releaseSendGate()
    do {
      _ = try await collectRecoveryContent(from: stream)
      XCTFail("Revoked request must terminate")
    } catch is CancellationError {
      // Expected: revocation crossed the already-authorized transport wait.
    }
    let count = await transport.requestCount
    XCTAssertEqual(count, 0)
  }

  func testRevocationBeforeProducerRegistrationCancelsThatProducer() async {
    let cancellation = AIChatStreamingRequestCancellation()
    cancellation.cancel()
    let task = Task<Void, Never> {
      try? await Task.sleep(for: .seconds(5))
    }
    cancellation.register(task)
    XCTAssertTrue(task.isCancelled)
    await task.value
  }

  func testPlainTextInterruptionRecoversWithTwoPOSTsWithoutDuplicateText() async throws {
    let transport = RecoveryStreamingTransport(attempts: [
      .init(
        lines: [
          #"data: {"choices":[{"delta":{"content":"Alpha paragraph.\n\nBeta"}}]}"#,
          "",
        ],
        terminalError: .connectionLost
      ),
      .init(lines: [
        #"data: {"choices":[{"delta":{"content":"Alpha paragraph.\n\nBeta continuation."},"finish_reason":"stop"}]}"#,
        "",
      ]),
    ])
    let client = makeClient(transport: transport, recoveryCount: 1)

    let stream = try await client.stream(
      request: AIChatCompletionRequest(
        model: "model",
        messages: [AIChatMessage(role: "user", content: "Write a paragraph.")]
      ),
      config: localConfig,
      apiKey: nil
    )

    let content = try await collectRecoveryContent(from: stream)
    XCTAssertEqual(content, "Alpha paragraph.\n\nBeta continuation.")
    let requestCount = await transport.requestCount()
    XCTAssertEqual(requestCount, 2)
    let secondBody = await transport.requestBodies()[1]
    XCTAssertTrue(String(data: secondBody, encoding: .utf8)?.contains("Beta") == true)
  }

  func testContinuationCarriesParagraphCheckpointAndIncompleteSentence() async throws {
    let transport = RecoveryStreamingTransport(attempts: [
      .init(
        lines: [
          #"data: {"choices":[{"delta":{"content":"第一段已完成。\n\n第二段尚未完成"}}]}"#,
          "",
        ],
        terminalError: .connectionLost
      ),
      .init(lines: [
        #"data: {"choices":[{"delta":{"content":"第二段尚未完成，继续写完。"},"finish_reason":"stop"}]}"#,
        "",
      ]),
    ])
    let client = makeClient(transport: transport, recoveryCount: 1)

    let stream = try await client.stream(
      request: AIChatCompletionRequest(
        model: "model",
        messages: [AIChatMessage(role: "user", content: "继续创作。")]
      ),
      config: localConfig,
      apiKey: nil
    )

    let content = try await collectRecoveryContent(from: stream)
    XCTAssertEqual(content, "第一段已完成。\n\n第二段尚未完成，继续写完。")

    let bodies = await transport.requestBodies()
    XCTAssertEqual(bodies.count, 2)
    let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: bodies[1]) as? [String: Any])
    let messages = try XCTUnwrap(payload["messages"] as? [[String: Any]])
    XCTAssertTrue(
      messages.contains {
        $0["role"] as? String == "assistant"
          && ($0["content"] as? String)?.contains("第一段已完成。\n\n第二段尚未完成") == true
      }
    )
  }

  func testContinuationOverlapSplitAcrossSSEDeltasIsRemoved() async throws {
    let transport = RecoveryStreamingTransport(attempts: [
      .init(
        lines: [
          #"data: {"choices":[{"delta":{"content":"Abase"}}]}"#,
          "",
        ],
        terminalError: .connectionLost
      ),
      .init(lines: [
        #"data: {"choices":[{"delta":{"content":"A"}}]}"#,
        "",
        #"data: {"choices":[{"delta":{"content":"base+new"},"finish_reason":"stop"}]}"#,
        "",
      ]),
    ])
    let client = makeClient(transport: transport, recoveryCount: 1)

    let stream = try await client.stream(
      request: AIChatCompletionRequest(
        model: "model",
        messages: [AIChatMessage(role: "user", content: "Continue.")]
      ),
      config: localConfig,
      apiKey: nil
    )

    var deltas: [String] = []
    for try await update in stream {
      deltas.append(update.contentDelta)
    }
    let content = deltas.joined()
    XCTAssertEqual(content, "Abase+new")
    let requestCount = await transport.requestCount()
    XCTAssertEqual(requestCount, 2)
  }

  func testToolCallStreamNeverStartsPlainTextRecovery() async throws {
    let transport = RecoveryStreamingTransport(attempts: [
      .init(
        lines: [
          #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"read","arguments":"{}"}}]}}]}"#,
          "",
        ],
        terminalError: .connectionLost
      ),
      .init(lines: [
        #"data: {"choices":[{"delta":{"content":"must not be sent"},"finish_reason":"stop"}]}"#,
        "",
      ]),
    ])
    let client = makeClient(transport: transport, recoveryCount: 1)
    let stream = try await client.stream(
      request: AIChatCompletionRequest(
        model: "model",
        messages: [AIChatMessage(role: "user", content: "Use a tool if needed.")]
      ),
      config: localConfig,
      apiKey: nil,
      purpose: .interactiveChat
    )

    do {
      _ = try await collectRecoveryContent(from: stream)
      XCTFail("Expected the tool-call stream to stop")
    } catch let error as AIChatCompletionClientError {
      XCTAssertFalse(error.didReceivePartialContent)
    }
    let requestCount = await transport.requestCount()
    XCTAssertEqual(requestCount, 1)
  }

  func testAuthorizationExpiryIsRecheckedBeforeContinuationPOST() async throws {
    let clock = AIChatRequestTestClock()
    let transport = AIChatPartialFailureTransport(expiring: clock)
    var client = makeClient(transport: transport, recoveryCount: 1)
    client.requestValidationDate = { clock.now() }
    let prepared = try client.prepareRequest(
      AIChatCompletionRequest(
        model: "model",
        messages: [AIChatMessage(role: "user", content: "Continue.")]
      ),
      config: localConfig,
      purpose: .interactiveChat,
      mode: .streaming
    )
    let authorized = prepared.bindingAuthorizationDeadline(
      clock.now().addingTimeInterval(60)
    )
    let stream = try await client.streamPrepared(
      authorized,
      config: localConfig,
      apiKey: nil
    )

    var content = ""
    do {
      for try await update in stream { content += update.contentDelta }
      XCTFail("Expired continuation must terminate")
    } catch let error as AIChatCompletionClientError {
      XCTAssertEqual(error.underlyingFailure, .preparedRequestAuthorizationExpired)
      XCTAssertTrue(error.didReceivePartialContent)
      XCTAssertFalse(error.isAutomaticallyRetryable)
      XCTAssertTrue(error.supportsManualRetry)
    }
    XCTAssertEqual(content, "partial")
    let requestCount = await transport.requestCount
    XCTAssertEqual(requestCount, 1)
  }

  func testContinuationHTTPFailurePreservesPartialCauseAndRetryAfterWithoutReplay() async throws {
    for status in [401, 429, 500] {
      let transport = AIChatPartialFailureTransport(statusCode: status)
      let client = makeClient(transport: transport, recoveryCount: 1)
      let stream = try await client.stream(
        request: AIChatCompletionRequest(
          model: "model", messages: [AIChatMessage(role: "user", content: "Continue.")]
        ), config: localConfig, apiKey: nil
      )
      var content = ""
      do {
        for try await update in stream { content += update.contentDelta }
        XCTFail("HTTP \(status) must terminate continuation")
      } catch let error as AIChatCompletionClientError {
        let expected = AIChatCompletionClientError.httpStatus(
          status, #"{"error":{"message":"continuation failed"}}"#,
          retryAfterSeconds: 45
        )
        XCTAssertEqual(error.underlyingFailure, expected)
        XCTAssertEqual(error.retryAfterSeconds, 45)
        XCTAssertEqual(error.recoverySuggestion, expected.recoverySuggestion)
        XCTAssertTrue(error.didReceivePartialContent)
        XCTAssertFalse(error.isAutomaticallyRetryable)
        XCTAssertTrue(error.supportsManualRetry)
        XCTAssertTrue(error.localizedDescription.contains("HTTP \(status)"))
        XCTAssertTrue(error.localizedDescription.contains("重复计费"))
      }
      XCTAssertEqual(content, "partial")
      let count = await transport.requestCount
      XCTAssertEqual(count, 2)
    }
  }

  func testCancellationStopsBeforeContinuationPOST() async throws {
    let transport = RecoveryStreamingTransport(attempts: [
      .init(
        lines: [
          #"data: {"choices":[{"delta":{"content":"partial"}}]}"#,
          "",
        ],
        terminalError: .connectionLost,
        delayNanoseconds: 500_000_000
      ),
      .init(lines: [
        #"data: {"choices":[{"delta":{"content":"must not be sent"},"finish_reason":"stop"}]}"#,
        "",
      ]),
    ])
    let client = makeClient(transport: transport, recoveryCount: 1)
    let stream = try await client.stream(
      request: AIChatCompletionRequest(
        model: "model",
        messages: [AIChatMessage(role: "user", content: "Continue.")]
      ),
      config: localConfig,
      apiKey: nil
    )

    let consumer = Task { () -> Error? in
      do {
        _ = try await collectRecoveryContent(from: stream)
        return nil
      } catch {
        return error
      }
    }
    try await Task.sleep(nanoseconds: 40_000_000)
    consumer.cancel()
    let error = await consumer.value
    // AsyncThrowingStream may end a cancelled iterator without surfacing a
    // CancellationError. The safety invariant is that cancellation never
    // crosses the second-POST boundary.
    XCTAssertFalse(error is AIChatCompletionClientError)
    let requestCount = await transport.requestCount()
    XCTAssertEqual(requestCount, 1)
  }

  func testRecoveryCountIsBoundedAndRetainsOriginalPartialError() async throws {
    let transport = RecoveryStreamingTransport(attempts: [
      .init(
        lines: [
          #"data: {"choices":[{"delta":{"content":"one"}}]}"#,
          "",
        ],
        terminalError: .connectionLost
      ),
      .init(
        lines: [
          #"data: {"choices":[{"delta":{"content":"one two"}}]}"#,
          "",
        ],
        terminalError: .connectionLost
      ),
      .init(lines: [
        #"data: {"choices":[{"delta":{"content":"three"},"finish_reason":"stop"}]}"#,
        "",
      ]),
    ])
    let client = makeClient(transport: transport, recoveryCount: 1)
    let stream = try await client.stream(
      request: AIChatCompletionRequest(
        model: "model",
        messages: [AIChatMessage(role: "user", content: "Continue.")]
      ),
      config: localConfig,
      apiKey: nil
    )

    var content = ""
    do {
      for try await update in stream {
        content += update.contentDelta
      }
      XCTFail("Expected the bounded recovery to stop")
    } catch let error as AIChatCompletionClientError {
      XCTAssertTrue(error.didReceivePartialContent)
    }
    XCTAssertEqual(content, "one two")
    let requestCount = await transport.requestCount()
    XCTAssertEqual(requestCount, 2)
  }

  private var localConfig: AIProviderConfig {
    AIProviderConfig(
      preset: .local,
      baseURL: "http://127.0.0.1:11434/v1",
      model: "model",
      requiresAPIKey: false
    )
  }

  private func makeClient(
    transport: any AIChatTransport,
    recoveryCount: Int
  ) -> AIChatCompletionClient {
    AIChatCompletionClient(
      transport: transport,
      networkRecoveryPolicy: AIChatNetworkRecoveryPolicy(
        firstByteTimeout: 1,
        resourceTimeout: 2,
        maximumAutomaticRetryCount: 0,
        automaticRetryBaseDelay: 0,
        partialTextRecovery: AIChatPartialTextRecoveryPolicy(
          maximumRecoveryCount: recoveryCount,
          checkpointCharacterCount: 8_192,
          overlapProbeCharacterCount: 8_192
        )
      )
    )
  }

}

private func collectRecoveryContent(
  from stream: AsyncThrowingStream<AIChatStreamUpdate, Error>
) async throws -> String {
  var content = ""
  for try await update in stream {
    content += update.contentDelta
  }
  return content
}

private enum RecoveryTransportError: Error, Sendable {
  case connectionLost
  case unexpectedDataRequest
}

private struct RecoveryAttempt: Sendable {
  var statusCode: Int = 200
  var lines: [String]
  var terminalError: RecoveryTransportError?
  var delayNanoseconds: UInt64

  init(
    statusCode: Int = 200,
    lines: [String],
    terminalError: RecoveryTransportError? = nil,
    delayNanoseconds: UInt64 = 0
  ) {
    self.statusCode = statusCode
    self.lines = lines
    self.terminalError = terminalError
    self.delayNanoseconds = delayNanoseconds
  }
}

private actor RecoveryStreamingTransport: AIChatStreamingTransport {
  private var attempts: [RecoveryAttempt]
  private var bodies: [Data] = []

  init(attempts: [RecoveryAttempt]) {
    self.attempts = attempts
  }

  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    throw RecoveryTransportError.unexpectedDataRequest
  }

  func lines(for request: URLRequest) async throws -> (
    AsyncThrowingStream<String, Error>, URLResponse
  ) {
    bodies.append(request.httpBody ?? Data())
    let attempt =
      attempts.isEmpty
      ? RecoveryAttempt(lines: [], terminalError: .connectionLost)
      : attempts.removeFirst()
    let response = HTTPURLResponse(
      url: request.url ?? URL(string: "http://127.0.0.1")!,
      statusCode: attempt.statusCode,
      httpVersion: nil,
      headerFields: nil
    )!
    let stream = AsyncThrowingStream<String, Error> { continuation in
      let task = Task {
        do {
          for line in attempt.lines {
            try Task.checkCancellation()
            continuation.yield(line)
          }
          if attempt.delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: attempt.delayNanoseconds)
          }
          if let terminalError = attempt.terminalError {
            continuation.finish(throwing: terminalError)
          } else {
            continuation.finish()
          }
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
    return (stream, response)
  }

  func requestCount() -> Int {
    bodies.count
  }

  func requestBodies() -> [Data] {
    bodies
  }
}
