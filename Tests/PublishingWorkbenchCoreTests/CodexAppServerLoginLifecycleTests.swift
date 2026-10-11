import Foundation
import XCTest

@testable import PublishingAICore

final class CodexAppServerLoginLifecycleTests: XCTestCase {
  func testCancelledBrowserAndDeviceStartsCleanUpLateResponsesOnce() async throws {
    for deviceCode in [false, true] {
      let transport = ControlledLoginTransport()
      let client = CodexAppServerClient(transport: transport)
      let start = Task {
        if deviceCode { return try await client.startChatGPTDeviceCodeLogin().loginID }
        return try await client.startChatGPTLogin().loginID
      }
      let sent = await transport.waitForMessage("account/login/start")
      XCTAssertTrue(sent)
      start.cancel()
      await assertError(.cancelled) { _ = try await start.value }
      // Even a completion before the late response must not retain a busy session.
      await transport.completeLogin()
      await transport.replyToLogin(deviceCode: deviceCode)
      await transport.completeLogin()
      let cancelled = await transport.waitForMessage("account/login/cancel")
      XCTAssertTrue(cancelled)
      _ = await client.reconnectAfterRuntimeUpdate()
      let ended = await transport.waitForTermination()
      XCTAssertTrue(ended)
      let count = await transport.count("account/login/cancel")
      XCTAssertEqual(count, 1)
    }
  }

  func testTimedOutStartCleansUpItsLateResponseAndAllowsReplacement() async throws {
    let transport = ControlledLoginTransport()
    let client = CodexAppServerClient(transport: transport, requestTimeout: .milliseconds(30))
    let start = Task { try await client.startChatGPTLogin() }
    let sent = await transport.waitForMessage("account/login/start")
    XCTAssertTrue(sent)
    await assertError(.requestTimedOut) { _ = try await start.value }
    await transport.replyToLogin()
    await transport.completeLogin()
    let cancelled = await transport.waitForMessage("account/login/cancel")
    XCTAssertTrue(cancelled)
    _ = await client.reconnectAfterRuntimeUpdate()
    let ended = await transport.waitForTermination()
    XCTAssertTrue(ended)
    let count = await transport.count("account/login/cancel")
    XCTAssertEqual(count, 1)
  }

  func testPendingCancellationRPCWakesReplacementAfterItsResponse() async throws {
    let transport = ControlledLoginTransport(holdCancellation: true)
    let client = CodexAppServerClient(transport: transport)
    let start = Task { try await client.startChatGPTLogin() }
    let sent = await transport.waitForMessage("account/login/start")
    XCTAssertTrue(sent)
    start.cancel()
    await assertError(.cancelled) { _ = try await start.value }
    await transport.replyToLogin()
    let cancelled = await transport.waitForMessage("account/login/cancel")
    XCTAssertTrue(cancelled)
    let replaced = await client.reconnectAfterRuntimeUpdate()
    XCTAssertFalse(replaced)
    await transport.replyToCancellation()
    let ended = await transport.waitForTermination()
    XCTAssertTrue(ended)
    let count = await transport.count("account/login/cancel")
    XCTAssertEqual(count, 1)
  }

  func testPreCancelledWaitStillCancelsTheRemoteLoginExactlyOnce() async throws {
    let transport = ControlledLoginTransport()
    let client = CodexAppServerClient(transport: transport)
    let start = Task { try await client.startChatGPTLogin() }
    let sent = await transport.waitForMessage("account/login/start")
    XCTAssertTrue(sent)
    await transport.replyToLogin()
    let login = try await start.value
    let wait = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      try await client.waitForLoginCompletion(loginID: login.loginID)
    }
    await assertError(.cancelled) { try await wait.value }
    let cancelled = await transport.waitForMessage("account/login/cancel")
    XCTAssertTrue(cancelled)
    let count = await transport.count("account/login/cancel")
    XCTAssertEqual(count, 1)
    await client.shutdown()
  }

  func testCompletionBeforeStartResponseIsClaimedAndConsumed() async throws {
    let transport = ControlledLoginTransport()
    let client = CodexAppServerClient(transport: transport)
    let start = Task { try await client.startChatGPTLogin() }
    let sent = await transport.waitForMessage("account/login/start")
    XCTAssertTrue(sent)
    await transport.completeLogin()
    await transport.replyToLogin()
    let login = try await start.value
    let replaced = await client.reconnectAfterRuntimeUpdate()
    XCTAssertFalse(replaced)
    try await client.waitForLoginCompletion(loginID: login.loginID)
    let ended = await transport.waitForTermination()
    XCTAssertTrue(ended)
    let count = await transport.count("account/login/cancel")
    XCTAssertEqual(count, 0)
  }

  func testEOFAfterStartBeforeWaitReturnsTheOriginalProcessError() async throws {
    let transport = ControlledLoginTransport()
    let client = CodexAppServerClient(transport: transport, loginTimeout: .milliseconds(100))
    let start = Task { try await client.startChatGPTLogin() }
    let sent = await transport.waitForMessage("account/login/start")
    XCTAssertTrue(sent)
    await transport.replyToLogin()
    let login = try await start.value
    await client.shutdown()
    await assertError(.endOfStream) {
      try await client.waitForLoginCompletion(loginID: login.loginID)
    }
    let count = await transport.count("account/login/cancel")
    XCTAssertEqual(count, 0)
  }

  func testOldGenerationCleanupDoesNotStartOrCancelTheReplacement() async throws {
    let first = ControlledLoginTransport()
    let second = ControlledLoginTransport()
    let factory = LoginTransportFactory([first, second])
    let client = CodexAppServerClient(transportFactory: { factory.next() })
    let start = Task { try await client.startChatGPTLogin() }
    let sent = await first.waitForMessage("account/login/start")
    XCTAssertTrue(sent)
    start.cancel()
    await assertError(.cancelled) { _ = try await start.value }
    await client.shutdown()
    _ = try await client.accountStatus()
    await first.replyToLogin()
    await first.completeLogin()
    _ = try await client.accountStatus()
    let count = await second.count("account/login/cancel")
    XCTAssertEqual(count, 0)
    XCTAssertEqual(factory.createdCount, 2)
    await client.shutdown()
  }

  func testTransportEOFAfterStartBeforeWaitReturnsTheOriginalError() async throws {
    let transport = ControlledLoginTransport()
    let client = CodexAppServerClient(transport: transport, loginTimeout: .seconds(1))
    let start = Task { try await client.startChatGPTLogin() }
    let sent = await transport.waitForMessage("account/login/start")
    XCTAssertTrue(sent)
    await transport.replyToLogin()
    let login = try await start.value
    await transport.terminate()
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    while await !client.transportEnded, clock.now < deadline {
      try await clock.sleep(for: .milliseconds(1))
    }
    let ended = await client.transportEnded
    XCTAssertTrue(ended)
    await assertError(.endOfStream) {
      try await client.waitForLoginCompletion(loginID: login.loginID)
    }
  }

  func testUnclaimedNotificationDoesNotDelayRuntimeReplacement() async throws {
    let transport = ControlledLoginTransport()
    let client = CodexAppServerClient(transport: transport)
    _ = try await client.accountStatus()
    await transport.completeLogin()
    _ = try await client.accountStatus()
    let replaced = await client.reconnectAfterRuntimeUpdate()
    XCTAssertTrue(replaced)
  }

  func testUnconsumedCompletedLoginExpiresAndWakesReplacement() async throws {
    let transport = ControlledLoginTransport()
    let client = CodexAppServerClient(transport: transport, loginTimeout: .milliseconds(100))
    let start = Task { try await client.startChatGPTLogin() }
    let sent = await transport.waitForMessage("account/login/start")
    XCTAssertTrue(sent)
    await transport.completeLogin()
    await transport.replyToLogin()
    let login = try await start.value
    let replaced = await client.reconnectAfterRuntimeUpdate()
    XCTAssertFalse(replaced)
    let ended = await transport.waitForTermination()
    XCTAssertTrue(ended)
    await assertError(.loginTimedOut) {
      try await client.waitForLoginCompletion(loginID: login.loginID)
    }
    let count = await transport.count("account/login/cancel")
    XCTAssertEqual(count, 0)
  }

  func testEOFClearsPendingReplacementForAnUnconsumedLogin() async throws {
    let transport = ControlledLoginTransport()
    let client = CodexAppServerClient(transport: transport)
    let start = Task { try await client.startChatGPTLogin() }
    let sent = await transport.waitForMessage("account/login/start")
    XCTAssertTrue(sent)
    await transport.replyToLogin()
    let login = try await start.value
    let replaced = await client.reconnectAfterRuntimeUpdate()
    XCTAssertFalse(replaced)
    await transport.terminate()
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    while await client.isRuntimeReconnectPending, clock.now < deadline {
      try await clock.sleep(for: .milliseconds(1))
    }
    let pending = await client.isRuntimeReconnectPending
    XCTAssertFalse(pending)
    await assertError(.endOfStream) {
      try await client.waitForLoginCompletion(loginID: login.loginID)
    }
  }

  func testQueuedOldExpiryCannotDiscardCompletionAfterTimerReplacement() async throws {
    let transport = ControlledLoginTransport()
    let client = CodexAppServerClient(transport: transport)
    let start = Task { try await client.startChatGPTLogin() }
    let sent = await transport.waitForMessage("account/login/start")
    XCTAssertTrue(sent)
    await transport.completeLogin()
    _ = try await client.accountStatus()
    let capturedTimerID = await client.loginState.expiryTokens["controlled-login"]
    let timerID = try XCTUnwrap(capturedTimerID)
    let generation = await client.transportGeneration
    await transport.replyToLogin()
    let login = try await start.value
    // Invoke the old callback after its sleep already returned and actor work queued.
    await client.expireLogin(loginID: login.loginID, timerID: timerID, generation: generation)
    try await client.waitForLoginCompletion(loginID: login.loginID)
    let count = await transport.count("account/login/cancel")
    XCTAssertEqual(count, 0)
    await client.shutdown()
  }

  func testQueuedOldExpiryCannotOverwriteEOFWithTimeout() async throws {
    let transport = ControlledLoginTransport()
    let client = CodexAppServerClient(transport: transport)
    let start = Task { try await client.startChatGPTLogin() }
    let sent = await transport.waitForMessage("account/login/start")
    XCTAssertTrue(sent)
    await transport.replyToLogin()
    let login = try await start.value
    let capturedTimerID = await client.loginState.expiryTokens[login.loginID]
    let timerID = try XCTUnwrap(capturedTimerID)
    let generation = await client.transportGeneration
    await client.shutdown()
    await client.expireLogin(loginID: login.loginID, timerID: timerID, generation: generation)
    await assertError(.endOfStream) {
      try await client.waitForLoginCompletion(loginID: login.loginID)
    }
  }

  func testStringLoginFailurePreservesItsSanitizedReason() async throws {
    let transport = ControlledLoginTransport()
    let client = CodexAppServerClient(transport: transport)
    let start = Task { try await client.startChatGPTLogin() }
    let sent = await transport.waitForMessage("account/login/start")
    XCTAssertTrue(sent)
    await transport.replyToLogin()
    let login = try await start.value
    await transport.completeLogin(success: false)
    await assertError(.rpc(code: nil, message: "Browser authorization denied")) {
      try await client.waitForLoginCompletion(loginID: login.loginID)
    }
    await client.shutdown()
  }

  private func assertError(
    _ expected: CodexAppServerError, operation: () async throws -> Void
  ) async {
    do {
      try await operation()
      XCTFail("Expected \(expected)")
    } catch {
      XCTAssertEqual(error as? CodexAppServerError, expected)
    }
  }
}

actor ControlledLoginTransport: CodexAppServerTransport {
  private let holdCancellation: Bool
  private var cancellationID: Int?
  private var messages: [CodexAppServerJSONValue] = []
  private var chunks: [Data] = []
  private var receiver: CheckedContinuation<Data?, Error>?
  private var terminated = false

  init(holdCancellation: Bool = false) { self.holdCancellation = holdCancellation }

  func start() async throws {}

  func send(_ data: Data) async throws {
    guard !terminated else { throw CodexAppServerError.endOfStream }
    let message = try JSONDecoder().decode(CodexAppServerJSONValue.self, from: data)
    messages.append(message)
    let id = message["id"]?.intValue ?? 0
    switch message["method"]?.stringValue {
    case "initialize": deliver("{\"id\":\(id),\"result\":{\"serverInfo\":{\"version\":\"1\"}}}")
    case "account/login/cancel":
      if holdCancellation { cancellationID = id } else { deliver("{\"id\":\(id),\"result\":{}}") }
    case "account/read":
      deliver(
        "{\"id\":\(id),\"result\":{\"authenticated\":true,\"account\":{\"type\":\"chatgpt\",\"id\":\"fixture\"}}}"
      )
    default: break
    }
  }

  func receive() async throws -> Data? {
    if !chunks.isEmpty { return chunks.removeFirst() }
    if terminated { return nil }
    return try await withCheckedThrowingContinuation { receiver = $0 }
  }

  func terminate() async {
    terminated = true
    receiver?.resume(returning: nil)
    receiver = nil
  }

  func replyToLogin(deviceCode: Bool = false) {
    guard
      let id = messages.first(where: { $0["method"]?.stringValue == "account/login/start" })?["id"]?
        .intValue
    else { return }
    let details =
      deviceCode
      ? "\"verificationUrl\":\"https://auth.example.test/device\",\"userCode\":\"ABCD-EFGH\""
      : "\"authUrl\":\"https://auth.example.test/browser\""
    deliver("{\"id\":\(id),\"result\":{\"loginId\":\"controlled-login\",\(details)}}")
  }

  func completeLogin(success: Bool = true) {
    let error = success ? "null" : "\"Browser authorization denied\""
    deliver(
      "{\"method\":\"account/login/completed\",\"params\":{\"loginId\":\"controlled-login\",\"success\":\(success),\"error\":\(error)}}"
    )
  }

  func count(_ method: String) -> Int {
    messages.filter { $0["method"]?.stringValue == method }.count
  }

  func replyToCancellation() {
    guard let id = cancellationID else { return }
    deliver("{\"id\":\(id),\"result\":{}}")
  }

  func waitForMessage(_ method: String) async -> Bool {
    await wait { self.count(method) > 0 }
  }

  func waitForTermination() async -> Bool { await wait { self.terminated } }

  private func wait(_ condition: () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    while !condition() {
      guard clock.now < deadline else { return false }
      try? await clock.sleep(for: .milliseconds(1))
    }
    return true
  }

  private func deliver(_ json: String) {
    guard !terminated else { return }
    let data = Data((json + "\n").utf8)
    if let receiver {
      self.receiver = nil
      receiver.resume(returning: data)
    } else {
      chunks.append(data)
    }
  }
}

private final class LoginTransportFactory: @unchecked Sendable {
  private let lock = NSLock()
  private var transports: [ControlledLoginTransport]
  private var count = 0
  init(_ transports: [ControlledLoginTransport]) { self.transports = transports }
  var createdCount: Int { lock.withLock { count } }
  func next() -> ControlledLoginTransport {
    lock.withLock {
      count += 1
      return transports.removeFirst()
    }
  }
}
