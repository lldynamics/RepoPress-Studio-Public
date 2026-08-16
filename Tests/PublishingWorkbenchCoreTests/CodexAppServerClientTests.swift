import Foundation
import XCTest

@testable import PublishingWorkbenchCore

final class CodexAppServerClientTests: XCTestCase {
  func testProcessTransportReturnsPartialPipeChunkWithoutWaitingForMaximum() async throws {
    let transport = CodexAppServerProcessTransport(
      executableURL: URL(fileURLWithPath: "/bin/cat"),
      arguments: []
    )
    try await transport.start()
    let payload = Data("small JSONL response\n".utf8)
    try await transport.send(payload)

    let received = expectation(description: "partial pipe chunk returned")
    let receiveTask = Task {
      let data = try await transport.receive()
      received.fulfill()
      return data
    }
    await fulfillment(of: [received], timeout: 1)
    await transport.terminate()

    let response = try await receiveTask.value
    XCTAssertEqual(response, payload)
  }

  func testHandshakeAndAccountReadAreRoutedByRequestID() async throws {
    let transport = ScriptedCodexTransport(mode: .account)
    let client = CodexAppServerClient(transport: transport)

    let account = try await client.accountStatus()

    XCTAssertTrue(account.isAuthenticated)
    XCTAssertEqual(account.accountID, "acct-1")
    XCTAssertEqual(account.accountType, "chatgpt")
    XCTAssertEqual(account.email, "writer@example.com")
    XCTAssertEqual(account.planType, "pro")

    let messages = await transport.sentMessages()
    XCTAssertEqual(
      messages.compactMap { $0["method"]?.stringValue },
      ["initialize", "initialized", "account/read"]
    )
    XCTAssertEqual(messages.compactMap { $0["id"]?.intValue }, [1, 2])
  }

  func testLoginUsesChatGPTTypeAndDoesNotSendCredentials() async throws {
    let transport = ScriptedCodexTransport(mode: .login)
    let client = CodexAppServerClient(transport: transport)

    let login = try await client.startChatGPTLogin()

    XCTAssertEqual(login.loginID, "login-7")
    XCTAssertEqual(login.authURL.absoluteString, "https://auth.example.test/device")
    let messages = await transport.sentMessages()
    let loginMessage = try XCTUnwrap(
      messages.first { $0["method"]?.stringValue == "account/login/start" })
    XCTAssertEqual(loginMessage["params"]?["type"]?.stringValue, "chatgpt")
    XCTAssertEqual(loginMessage["params"]?["useHostedLoginSuccessPage"]?.boolValue, true)
    XCTAssertEqual(loginMessage["params"]?["appBrand"]?.stringValue, "chatgpt")
    let serialized = String(data: await transport.sentBytes(), encoding: .utf8) ?? ""
    XCTAssertFalse(serialized.localizedCaseInsensitiveContains("token"))
    XCTAssertFalse(serialized.localizedCaseInsensitiveContains("authorization"))
  }

  func testLoginCompletionNotificationResumesWaiter() async throws {
    let transport = ScriptedCodexTransport(mode: .loginCompletion)
    let client = CodexAppServerClient(transport: transport)

    let login = try await client.startChatGPTLogin()
    try await client.waitForLoginCompletion(loginID: login.loginID)

    XCTAssertEqual(login.loginID, "login-7")
  }

  func testLoginFailureNotificationIsSurfaced() async throws {
    let transport = ScriptedCodexTransport(mode: .loginFailure)
    let client = CodexAppServerClient(transport: transport)
    let login = try await client.startChatGPTLogin()

    await XCTAssertThrowsErrorAsync(
      try await client.waitForLoginCompletion(loginID: login.loginID)
    ) { error in
      XCTAssertEqual(
        error as? CodexAppServerError,
        .rpc(code: nil, message: "Browser authorization was denied")
      )
    }
  }

  func testDeviceCodeLoginReturnsVerificationDetails() async throws {
    let transport = ScriptedCodexTransport(mode: .deviceCode)
    let client = CodexAppServerClient(transport: transport)

    let login = try await client.startChatGPTDeviceCodeLogin()

    XCTAssertEqual(login.loginID, "login-device-1")
    XCTAssertEqual(login.verificationURL.absoluteString, "https://auth.example.test/device")
    XCTAssertEqual(login.userCode, "ABCD-EFGH")
    let messages = await transport.sentMessages()
    let loginMessage = try XCTUnwrap(
      messages.first { $0["method"]?.stringValue == "account/login/start" })
    XCTAssertEqual(loginMessage["params"]?["type"]?.stringValue, "chatgptDeviceCode")
  }

  func testCancellingLoginWaitCancelsRemoteLogin() async throws {
    let transport = ScriptedCodexTransport(mode: .hangingLogin)
    let client = CodexAppServerClient(transport: transport)
    let login = try await client.startChatGPTLogin()
    let task = Task {
      try await client.waitForLoginCompletion(loginID: login.loginID)
    }

    task.cancel()
    await XCTAssertThrowsErrorAsync(try await task.value) { error in
      XCTAssertEqual(error as? CodexAppServerError, .cancelled)
    }
    let didSendCancel = await transport.waitUntilSent(method: "account/login/cancel")
    XCTAssertTrue(didSendCancel, "Timed out waiting for account/login/cancel")
    let messages = await transport.sentMessages()
    let cancelMessage = try XCTUnwrap(
      messages.first { $0["method"]?.stringValue == "account/login/cancel" }
    )
    XCTAssertEqual(cancelMessage["params"]?["loginId"]?.stringValue, "login-7")
  }

  func testRateLimitsAndLogoutUseTypedResponses() async throws {
    let transport = ScriptedCodexTransport(mode: .rateLimits)
    let client = CodexAppServerClient(transport: transport)

    let limits = try await client.rateLimits()
    try await client.logout()

    XCTAssertEqual(limits.primary?.usedPercent, 25)
    XCTAssertEqual(limits.primary?.windowMinutes, 300)
    XCTAssertEqual(limits.creditsRemaining, 42)
    XCTAssertEqual(limits.planType, "pro")
    let messages = await transport.sentMessages()
    XCTAssertEqual(
      messages.compactMap { $0["method"]?.stringValue },
      ["initialize", "initialized", "account/rateLimits/read", "account/logout"]
    )
  }

  func testChunkedJSONLAndAgentMessageDeltasProduceCompletion() async throws {
    let transport = ScriptedCodexTransport(mode: .completion)
    let client = CodexAppServerClient(transport: transport)

    let completion = try await client.complete(
      prompt: "Write a short title",
      model: "gpt-5-codex",
      workingDirectory: URL(fileURLWithPath: "/tmp/project")
    )

    XCTAssertEqual(completion.text, "Hello world")
    XCTAssertEqual(completion.threadID, "thread-1")
    XCTAssertEqual(completion.turnID, "turn-1")
    XCTAssertEqual(completion.model, "gpt-5-codex")

    let messages = await transport.sentMessages()
    let threadStart = try XCTUnwrap(messages.first { $0["method"]?.stringValue == "thread/start" })
    XCTAssertEqual(threadStart["params"]?["ephemeral"]?.boolValue, true)
    XCTAssertEqual(threadStart["params"]?["sandbox"]?.stringValue, "read-only")
    XCTAssertEqual(threadStart["params"]?["approvalPolicy"]?.stringValue, "never")
    XCTAssertTrue(
      threadStart["params"]?["developerInstructions"]?.stringValue?.contains(
        "Never inspect the filesystem") == true
    )
    XCTAssertEqual(threadStart["params"]?["cwd"]?.stringValue, "/tmp/project")
    let turnStart = try XCTUnwrap(messages.first { $0["method"]?.stringValue == "turn/start" })
    XCTAssertEqual(turnStart["params"]?["threadId"]?.stringValue, "thread-1")
    XCTAssertEqual(
      turnStart["params"]?["input"]?.arrayValue?.first?["text"]?.stringValue, "Write a short title")
  }

  func testTurnFailedIsSurfacedAsTypedError() async throws {
    let transport = ScriptedCodexTransport(mode: .turnFailure)
    let client = CodexAppServerClient(transport: transport)

    await XCTAssertThrowsErrorAsync(
      try await client.complete(prompt: "fail")
    ) { error in
      XCTAssertEqual(error as? CodexAppServerError, .turnFailed("model unavailable"))
    }
  }

  func testCompletedFailureStatusIsSurfacedAsTypedError() async throws {
    let transport = ScriptedCodexTransport(mode: .completedFailure)
    let client = CodexAppServerClient(transport: transport)

    await XCTAssertThrowsErrorAsync(
      try await client.complete(prompt: "fail")
    ) { error in
      XCTAssertEqual(error as? CodexAppServerError, .turnFailed("quota exceeded"))
    }
  }

  func testEOFFailsPendingRequest() async throws {
    let transport = ScriptedCodexTransport(mode: .eofAfterHandshake)
    let client = CodexAppServerClient(transport: transport)

    await XCTAssertThrowsErrorAsync(
      try await client.accountStatus()
    ) { error in
      XCTAssertEqual(error as? CodexAppServerError, .endOfStream)
    }
  }

  func testCancellingActiveCompletionInterruptsRemoteTurn() async throws {
    let transport = ScriptedCodexTransport(mode: .hangingTurn)
    let client = CodexAppServerClient(transport: transport)
    let task = Task {
      try await client.complete(prompt: "cancel this turn")
    }

    let didSendTurnStart = await transport.waitUntilSent(method: "turn/start")
    guard didSendTurnStart else {
      task.cancel()
      _ = await task.result
      XCTFail("Timed out waiting for turn/start")
      return
    }
    let activeTurn = await waitForActiveTurn(client: client)
    guard let activeTurn else {
      task.cancel()
      _ = await task.result
      XCTFail("Timed out waiting for an active turn")
      return
    }
    XCTAssertEqual(activeTurn.threadID, "thread-1")
    XCTAssertEqual(activeTurn.turnID, "turn-1")
    task.cancel()
    await XCTAssertThrowsErrorAsync(try await task.value) { error in
      XCTAssertEqual(error as? CodexAppServerError, .cancelled)
    }
    let didSendInterrupt = await transport.waitUntilSent(method: "turn/interrupt")
    XCTAssertTrue(didSendInterrupt, "Timed out waiting for turn/interrupt")

    let messages = await transport.sentMessages()
    let interrupt = try XCTUnwrap(
      messages.first { $0["method"]?.stringValue == "turn/interrupt" }
    )
    XCTAssertEqual(interrupt["params"]?["threadId"]?.stringValue, "thread-1")
    XCTAssertEqual(interrupt["params"]?["turnId"]?.stringValue, "turn-1")
  }

}

private actor ScriptedCodexTransport: CodexAppServerTransport {
  enum Mode: Equatable {
    case account
    case login
    case loginCompletion
    case loginFailure
    case deviceCode
    case hangingLogin
    case rateLimits
    case completion
    case turnFailure
    case completedFailure
    case hangingTurn
    case eofAfterHandshake
  }

  private let mode: Mode
  private var queuedChunks: [Data] = []
  private var waitingReceivers: [CheckedContinuation<Data?, Error>] = []
  private var messages: [CodexAppServerJSONValue] = []
  private var bytes = Data()
  private var isClosed = false

  init(mode: Mode) {
    self.mode = mode
  }

  func start() async throws {}

  func send(_ data: Data) async throws {
    guard !isClosed else { throw CodexAppServerError.endOfStream }
    bytes.append(data)
    let line = data.drop(while: { $0 == 0x20 || $0 == 0x09 || $0 == 0x0A || $0 == 0x0D })
    guard let object = try? JSONDecoder().decode(CodexAppServerJSONValue.self, from: line),
      let method = object["method"]?.stringValue
    else { return }
    messages.append(object)

    switch method {
    case "initialize":
      enqueue(
        json: #"""
          {"id":1,"result":{"serverInfo":{"version":"1"}}}
          """#)
    case "account/read":
      enqueue(
        json: #"""
          {"id":2,"result":{"account":{"id":"acct-1","type":"chatgpt","email":"writer@example.com","planType":"pro"},"requiresOpenaiAuth":true}}
          """#)
    case "account/login/start":
      if mode == .deviceCode {
        enqueue(
          json: #"""
            {"id":2,"result":{"loginId":"login-device-1","verificationUrl":"https://auth.example.test/device","userCode":"ABCD-EFGH"}}
            """#)
      } else if mode == .loginCompletion {
        enqueue(
          json: #"""
            {"id":2,"result":{"loginId":"login-7","authUrl":"https://auth.example.test/device"}}
            {"method":"account/login/completed","params":{"loginId":"login-7","success":true}}
            """#)
      } else if mode == .loginFailure {
        enqueue(
          json: #"""
            {"id":2,"result":{"loginId":"login-7","authUrl":"https://auth.example.test/device"}}
            {"method":"account/login/completed","params":{"loginId":"login-7","success":false,"error":{"message":"Browser authorization was denied"}}}
            """#)
      } else {
        enqueue(
          json: #"""
            {"id":2,"result":{"loginId":"login-7","authUrl":"https://auth.example.test/device"}}
            """#)
      }
    case "account/login/cancel":
      enqueue(
        json: #"""
          {"id":3,"result":{}}
          """#)
    case "account/rateLimits/read":
      enqueue(
        json: #"""
          {"id":2,"result":{"rateLimits":{"primary":{"usedPercent":25,"windowDurationMins":300},"creditsRemaining":42,"planType":"pro"}}}
          """#)
    case "account/logout":
      enqueue(
        json: #"""
          {"id":3,"result":{}}
          """#)
    case "thread/start":
      enqueue(
        json: #"""
          {"id":2,"result":{"thread":{"id":"thread-1","model":"gpt-5-codex"}}}
          """#)
    case "turn/start":
      switch mode {
      case .turnFailure:
        enqueue(
          json: #"""
            {"id":3,"result":{"turn":{"id":"turn-1"}}}
            {"method":"turn/failed","params":{"threadId":"thread-1","turnId":"turn-1","error":{"message":"model unavailable"}}}
            """#)
      case .completedFailure:
        enqueue(
          json: #"""
            {"id":3,"result":{"turn":{"id":"turn-1"}}}
            {"method":"turn/completed","params":{"threadId":"thread-1","turnId":"turn-1","turn":{"id":"turn-1","status":"failed","error":{"message":"quota exceeded"}}}}
            """#)
      case .hangingTurn:
        enqueue(
          json: #"""
            {"id":3,"result":{"turn":{"id":"turn-1"}}}
            """#)
      default:
        enqueue(
          json: #"""
            {"id":3,"result":{"turn":{"id":"turn-1"}}}
            {"method":"item/agentMessage/delta","params":{"threadId":"thread-1","turnId":"turn-1","delta":"Hello "}}
            {"method":"item/agentMessage/delta","params":{"threadId":"thread-1","turnId":"turn-1","delta":"world"}}
            {"method":"turn/completed","params":{"threadId":"thread-1","turnId":"turn-1"}}
            """#)
      }
    case "turn/interrupt":
      if mode == .hangingTurn {
        enqueue(
          json: #"""
            {"id":4,"result":{}}
            """#)
      }
    case "initialized":
      if mode == .eofAfterHandshake {
        close()
      }
    default:
      break
    }
  }

  func receive() async throws -> Data? {
    if !queuedChunks.isEmpty {
      return queuedChunks.removeFirst()
    }
    if isClosed {
      return nil
    }
    return try await withCheckedThrowingContinuation { continuation in
      waitingReceivers.append(continuation)
    }
  }

  func terminate() async {
    close()
  }

  func sentMessages() -> [CodexAppServerJSONValue] {
    messages
  }

  func sentBytes() -> Data {
    bytes
  }

  func waitUntilSent(method: String, timeout: Duration = .seconds(5)) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !messages.contains(where: { $0["method"]?.stringValue == method }) {
      guard clock.now < deadline else { return false }
      try? await clock.sleep(for: .milliseconds(1))
    }
    return true
  }

  private func enqueue(json: String) {
    let data = Data((json + "\n").utf8)
    guard mode == .completion || mode == .turnFailure || json.contains("serverInfo") else {
      deliver(data)
      return
    }

    if mode == .completion || mode == .turnFailure {
      // Feed stdout in deliberately awkward chunks so the client must assemble JSONL lines.
      let splitPoints = [min(7, data.count), min(19, data.count)]
      var start = data.startIndex
      for point in splitPoints where point > start {
        let end = data.index(data.startIndex, offsetBy: point)
        deliver(Data(data[start..<end]))
        start = end
      }
      if start < data.endIndex {
        deliver(Data(data[start..<data.endIndex]))
      }
    } else {
      deliver(data)
    }
  }

  private func deliver(_ data: Data) {
    if let receiver = waitingReceivers.first {
      waitingReceivers.removeFirst()
      receiver.resume(returning: data)
    } else {
      queuedChunks.append(data)
    }
  }

  private func close() {
    isClosed = true
    let receivers = waitingReceivers
    waitingReceivers.removeAll()
    for receiver in receivers {
      receiver.resume(returning: nil)
    }
  }
}

private func waitForActiveTurn(
  client: CodexAppServerClient,
  timeout: Duration = .seconds(5)
) async -> CodexAppServerClient.ActiveTurnSnapshot? {
  let clock = ContinuousClock()
  let deadline = clock.now.advanced(by: timeout)
  while true {
    if let snapshot = await client.activeTurnSnapshot {
      return snapshot
    }
    guard clock.now < deadline else { return nil }
    try? await clock.sleep(for: .milliseconds(1))
  }
}

private func XCTAssertThrowsErrorAsync<T>(
  _ expression: @autoclosure () async throws -> T,
  _ handler: (Error) -> Void
) async {
  do {
    _ = try await expression()
    XCTFail("Expected expression to throw")
  } catch {
    handler(error)
  }
}
