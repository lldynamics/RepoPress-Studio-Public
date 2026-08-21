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

  func testAccountRequiresAuthWinsOverStaleAccountMetadata() async throws {
    let transport = ScriptedCodexTransport(mode: .accountRequiresAuth)
    let client = CodexAppServerClient(transport: transport)

    let account = try await client.accountStatus()

    XCTAssertFalse(account.isAuthenticated)
    XCTAssertEqual(account.accountID, "stale-acct")
  }

  func testAccountMetadataInfersAuthenticationWhenFlagsAreAbsent() async throws {
    let transport = ScriptedCodexTransport(mode: .accountMetadataOnly)
    let client = CodexAppServerClient(transport: transport)

    let account = try await client.accountStatus()

    XCTAssertTrue(account.isAuthenticated)
    XCTAssertEqual(account.accountID, "metadata-acct")
  }

  func testLoginRejectsNonHTTPSOrHostlessAuthURL() async throws {
    for mode in [
      ScriptedCodexTransport.Mode.loginInsecureURL,
      .loginHostlessURL,
      .loginUserInfoURL,
    ] {
      let transport = ScriptedCodexTransport(mode: mode)
      let client = CodexAppServerClient(transport: transport)

      await XCTAssertThrowsErrorAsync(try await client.startChatGPTLogin()) { error in
        XCTAssertEqual(error as? CodexAppServerError, .invalidResponse)
        XCTAssertFalse(String(describing: error).contains("token"))
      }
    }
  }

  func testDeviceCodeLoginRejectsNonHTTPSOrHostlessVerificationURL() async throws {
    for mode in [ScriptedCodexTransport.Mode.deviceCodeInsecureURL, .deviceCodeHostlessURL] {
      let transport = ScriptedCodexTransport(mode: mode)
      let client = CodexAppServerClient(transport: transport)

      await XCTAssertThrowsErrorAsync(try await client.startChatGPTDeviceCodeLogin()) { error in
        XCTAssertEqual(error as? CodexAppServerError, .invalidResponse)
      }
    }
  }

  func testLoginUsesChatGPTTypeAndDoesNotSendCredentials() async throws {
    let transport = ScriptedCodexTransport(mode: .login)
    let client = CodexAppServerClient(transport: transport)

    let login = try await client.startChatGPTLogin()

    XCTAssertEqual(login.loginID, "login-7")
    XCTAssertEqual(login.authURL.absoluteString, "https://auth.example.test/device?state=opaque")
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

  func testLateLoginCompletionAfterCancellationIsNotBufferedAsSuccess() async throws {
    let transport = ScriptedCodexTransport(mode: .lateCompletionAfterCancel)
    let client = CodexAppServerClient(
      transport: transport,
      loginTimeout: .milliseconds(20)
    )
    let login = try await client.startChatGPTLogin()
    let waitTask = Task {
      try await client.waitForLoginCompletion(loginID: login.loginID)
    }

    for _ in 0..<100 {
      if await client.loginWaiterCount != 0 { break }
      await Task.yield()
    }
    let waiterCount = await client.loginWaiterCount
    XCTAssertEqual(waiterCount, 1)

    await client.cancelLogin(loginID: login.loginID)
    await XCTAssertThrowsErrorAsync(try await waitTask.value) { error in
      XCTAssertEqual(error as? CodexAppServerError, .cancelled)
    }

    await XCTAssertThrowsErrorAsync(
      try await client.waitForLoginCompletion(loginID: login.loginID)
    ) { error in
      XCTAssertEqual(error as? CodexAppServerError, .loginTimedOut)
    }
    let cancelCount = await transport.sentMessageCount(method: "account/login/cancel")
    XCTAssertEqual(cancelCount, 1)
  }

  func testLoginWaitTimeoutCancelsOnceClearsWaiterAndKeepsRPCUsable() async throws {
    let transport = ScriptedCodexTransport(mode: .hangingLogin)
    let client = CodexAppServerClient(
      transport: transport,
      loginTimeout: .milliseconds(20)
    )
    let login = try await client.startChatGPTLogin()

    await XCTAssertThrowsErrorAsync(
      try await client.waitForLoginCompletion(loginID: login.loginID)
    ) { error in
      XCTAssertEqual(error as? CodexAppServerError, .loginTimedOut)
      XCTAssertFalse(String(describing: error).contains("login-7"))
      XCTAssertFalse(String(describing: error).contains("http"))
    }

    let waiterCountAfterTimeout = await client.loginWaiterCount
    XCTAssertEqual(waiterCountAfterTimeout, 0)
    let didSendCancel = await transport.waitUntilSent(method: "account/login/cancel")
    XCTAssertTrue(didSendCancel, "Timed out waiting for account/login/cancel")
    // Allow the timeout task to finish its best-effort remote cancellation,
    // then ensure a cancellation handler cannot send a second request.
    try await Task.sleep(for: .milliseconds(20))
    let cancelCount = await transport.sentMessageCount(method: "account/login/cancel")
    XCTAssertEqual(cancelCount, 1)

    let account = try await client.accountStatus()
    XCTAssertTrue(account.isAuthenticated)
    XCTAssertEqual(account.accountID, "acct-1")
    let waiterCountAfterRPC = await client.loginWaiterCount
    XCTAssertEqual(waiterCountAfterRPC, 0)
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

  func testModelListReturnsVisibleModelsAndSupportsMissingOptionalFields() async throws {
    let transport = ScriptedCodexTransport(mode: .modelCatalogSingle)
    let client = CodexAppServerClient(transport: transport)

    let models = try await client.models()

    XCTAssertEqual(models.map(\.id), ["visible-model"])
    let model = try XCTUnwrap(models.first)
    XCTAssertEqual(model.model, "visible-model")
    XCTAssertEqual(model.displayName, "Visible Model")
    XCTAssertEqual(model.description, "A visible model")
    XCTAssertFalse(model.hidden)
    XCTAssertEqual(model.defaultReasoningEffort, "medium")
    XCTAssertEqual(model.supportedReasoningEfforts.map(\.reasoningEffort), ["low", "high"])
    XCTAssertEqual(model.inputModalities, ["text"])
    XCTAssertTrue(model.isDefault)
    XCTAssertEqual(model.upgrade, "pro")

    let decoder = JSONDecoder()
    let modelOnly = try decoder.decode(
      CodexAppServerModel.self,
      from: Data(#"{"model":" model-only "}"#.utf8)
    )
    XCTAssertEqual(modelOnly.id, "model-only")
    XCTAssertEqual(modelOnly.displayName, "model-only")
    XCTAssertEqual(modelOnly.inputModalities, ["text", "image"])

    let messages = await transport.sentMessages()
    let request = try XCTUnwrap(messages.first { $0["method"]?.stringValue == "model/list" })
    XCTAssertEqual(request["params"]?["includeHidden"]?.boolValue, false)
    XCTAssertEqual(request["params"]?["limit"]?.intValue, 100)
  }

  func testModelListFollowsCursorPaginationAndCanIncludeHiddenModels() async throws {
    let transport = ScriptedCodexTransport(mode: .modelCatalogPagination)
    let client = CodexAppServerClient(transport: transport)

    let models = try await client.models(includeHidden: true)

    XCTAssertEqual(models.map(\.id), ["page-one-model", "hidden-model", "page-two-model"])
    let messages = await transport.sentMessages()
    let requests = messages.filter { $0["method"]?.stringValue == "model/list" }
    XCTAssertEqual(requests.count, 2)
    XCTAssertNil(requests[0]["params"]?["cursor"]?.stringValue)
    XCTAssertEqual(requests[1]["params"]?["cursor"]?.stringValue, "page-two")
    XCTAssertTrue(requests.allSatisfy { $0["params"]?["includeHidden"]?.boolValue == true })
  }

  func testModelListStopsWhenServerRepeatsCursor() async throws {
    let transport = ScriptedCodexTransport(mode: .modelCatalogLoop)
    let client = CodexAppServerClient(transport: transport)

    let models = try await client.models()

    XCTAssertEqual(models.map(\.id), ["loop-one", "loop-two"])
    let requests = await transport.sentMessages().filter {
      $0["method"]?.stringValue == "model/list"
    }
    XCTAssertEqual(requests.count, 2)
  }

  func testModelListRejectsAbnormalResponse() async throws {
    let transport = ScriptedCodexTransport(mode: .modelCatalogInvalid)
    let client = CodexAppServerClient(transport: transport)

    await XCTAssertThrowsErrorAsync(try await client.models()) { error in
      XCTAssertEqual(error as? CodexAppServerError, .invalidResponse)
    }
  }

  func testChunkedJSONLAndAgentMessageDeltasProduceCompletion() async throws {
    let transport = ScriptedCodexTransport(mode: .completion)
    let client = CodexAppServerClient(transport: transport)

    let completion = try await client.complete(
      prompt: "Write a short title",
      model: " gpt-5-codex ",
      reasoningEffort: " high ",
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
    XCTAssertEqual(turnStart["params"]?["effort"]?.stringValue, "high")
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

  func testRPCRequestTimeoutCleansPendingContinuationAndIgnoresLateResponse() async throws {
    let transport = ScriptedCodexTransport(mode: .lateAccountResponse)
    let client = CodexAppServerClient(
      transport: transport,
      requestTimeout: .milliseconds(20)
    )

    await XCTAssertThrowsErrorAsync(try await client.accountStatus()) { error in
      XCTAssertEqual(error as? CodexAppServerError, .requestTimedOut)
    }

    // The delayed response for request 2 must not resume a consumed
    // continuation. A later request remains usable and is routed by its own
    // request ID.
    try await Task.sleep(for: .milliseconds(40))
    let account = try await client.accountStatus()
    XCTAssertEqual(account.accountID, "acct-1")
    let accountReadCount = await transport.sentMessageCount(method: "account/read")
    XCTAssertEqual(accountReadCount, 2)
  }

  func testTurnTimeoutInterruptsAndCleansActiveTurn() async throws {
    let transport = ScriptedCodexTransport(mode: .hangingTurn)
    let client = CodexAppServerClient(
      transport: transport,
      turnTimeout: .milliseconds(20)
    )

    await XCTAssertThrowsErrorAsync(try await client.complete(prompt: "timeout this turn")) { error in
      XCTAssertEqual(error as? CodexAppServerError, .turnTimedOut)
    }
    let didSendInterrupt = await transport.waitUntilSent(method: "turn/interrupt")
    XCTAssertTrue(didSendInterrupt, "Timed out waiting for turn/interrupt")
    let activeTurn = await client.activeTurnSnapshot
    XCTAssertNil(activeTurn)
  }

  func testEOFStartsFreshTransportGenerationOnNextOperation() async throws {
    let factory = SequencedCodexTransportFactory()
    let client = CodexAppServerClient(
      transportFactory: { factory.make() },
      requestTimeout: .milliseconds(100)
    )

    await XCTAssertThrowsErrorAsync(try await client.accountStatus()) { error in
      XCTAssertEqual(error as? CodexAppServerError, .endOfStream)
    }

    let account = try await client.accountStatus()
    XCTAssertTrue(account.isAuthenticated)
    XCTAssertEqual(account.accountID, "acct-1")
    XCTAssertEqual(factory.makeCount, 2)
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

  func testDynamicToolCallIsReturnedToHostAndAcknowledgedWithoutLocalExecution() async throws {
    let transport = ScriptedCodexTransport(mode: .dynamicTool)
    let client = CodexAppServerClient(
      transport: transport,
      requestTimeout: .seconds(1),
      turnTimeout: .seconds(1)
    )
    let tool = AIToolDefinition(
      function: AIToolFunctionDefinition(
        name: "createDraft",
        description: "Create a blank local draft.",
        parameters: .object([
          "type": .string("object"),
          "properties": .object([
            "value": .object(["type": .string("string")])
          ]),
          "additionalProperties": .bool(false),
        ])
      )
    )

    let completion = try await client.complete(
      prompt: "Create one draft.",
      dynamicTools: [tool]
    )

    XCTAssertEqual(completion.text, "")
    XCTAssertEqual(completion.toolCalls.count, 1)
    XCTAssertEqual(completion.toolCalls.first?.id, "dynamic-call-1")
    XCTAssertEqual(completion.toolCalls.first?.function.name, "createDraft")
    XCTAssertEqual(
      completion.toolCalls.first?.function.arguments,
      #"{"value":"Codex 动态文章"}"#
    )

    let messages = await transport.sentMessages()
    let threadStart = try XCTUnwrap(
      messages.first { $0["method"]?.stringValue == "thread/start" }
    )
    let dynamicTools = try XCTUnwrap(
      threadStart["params"]?["dynamicTools"]?.arrayValue
    )
    XCTAssertEqual(dynamicTools.first?["name"]?.stringValue, "createDraft")
    let response = try XCTUnwrap(
      messages.first { $0["id"]?.intValue == 91 && $0["method"] == nil }
    )
    XCTAssertEqual(response["result"]?["success"]?.boolValue, true)
  }

}

private actor ScriptedCodexTransport: CodexAppServerTransport {
  enum Mode: Equatable {
    case account
    case accountRequiresAuth
    case accountMetadataOnly
    case login
    case loginInsecureURL
    case loginHostlessURL
    case loginUserInfoURL
    case loginCompletion
    case loginFailure
    case lateCompletionAfterCancel
    case deviceCode
    case deviceCodeInsecureURL
    case deviceCodeHostlessURL
    case hangingLogin
    case rateLimits
    case modelCatalogSingle
    case modelCatalogPagination
    case modelCatalogLoop
    case modelCatalogInvalid
    case completion
    case turnFailure
    case completedFailure
    case hangingTurn
    case dynamicTool
    case lateAccountResponse
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
    guard let object = try? JSONDecoder().decode(CodexAppServerJSONValue.self, from: line)
    else { return }
    messages.append(object)
    guard let method = object["method"]?.stringValue else {
      if mode == .dynamicTool, object["id"]?.intValue == 91 {
        enqueue(
          json: #"""
            {"method":"turn/completed","params":{"threadId":"thread-1","turnId":"turn-1"}}
            """#
        )
      }
      return
    }
    let requestID = object["id"]?.intValue ?? 0

    switch method {
    case "initialize":
      enqueue(
        json: """
          {"id":\(requestID),"result":{"serverInfo":{"version":"1"}}}
          """
      )
    case "account/read":
      if mode == .lateAccountResponse && requestID == 2 {
        Task { [weak self] in
          try? await Task.sleep(for: .milliseconds(50))
          await self?.enqueue(
            json: """
              {"id":\(requestID),"result":{"authenticated":true,"account":{"id":"late-acct","type":"chatgpt"}}}
              """
          )
        }
      } else if mode == .accountRequiresAuth {
        enqueue(
          json: """
            {"id":\(requestID),"result":{"authenticated":false,"account":{"id":"stale-acct","type":"chatgpt","email":"stale@example.com"},"requiresOpenaiAuth":true}}
            """
        )
      } else if mode == .accountMetadataOnly {
        enqueue(
          json: """
            {"id":\(requestID),"result":{"account":{"id":"metadata-acct","type":"chatgpt","email":"metadata@example.com"}}}
            """
        )
      } else {
        enqueue(
          json: """
            {"id":\(requestID),"result":{"authenticated":true,"account":{"id":"acct-1","type":"chatgpt","email":"writer@example.com","planType":"pro"},"requiresOpenaiAuth":true}}
            """
        )
      }
    case "account/login/start":
      if mode == .deviceCode {
        enqueue(
          json: #"""
            {"id":2,"result":{"loginId":"login-device-1","verificationUrl":"https://auth.example.test/device","userCode":"ABCD-EFGH"}}
            """#)
      } else if mode == .deviceCodeInsecureURL {
        enqueue(
          json: #"""
            {"id":2,"result":{"loginId":"login-device-1","verificationUrl":"http://auth.example.test/device","userCode":"ABCD-EFGH"}}
            """#)
      } else if mode == .deviceCodeHostlessURL {
        enqueue(
          json: #"""
            {"id":2,"result":{"loginId":"login-device-1","verificationUrl":"https:///device","userCode":"ABCD-EFGH"}}
            """#)
      } else if mode == .loginInsecureURL {
        enqueue(
          json: #"""
            {"id":2,"result":{"loginId":"login-7","authUrl":"http://auth.example.test/device?token=secret"}}
            """#)
      } else if mode == .loginHostlessURL {
        enqueue(
          json: #"""
            {"id":2,"result":{"loginId":"login-7","authUrl":"https:///device?token=secret"}}
            """#)
      } else if mode == .loginUserInfoURL {
        enqueue(
          json: #"""
            {"id":2,"result":{"loginId":"login-7","authUrl":"https://user:password@auth.example.test/device?token=secret"}}
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
            {"id":2,"result":{"loginId":"login-7","authUrl":"https://auth.example.test/device?state=opaque"}}
            """#)
      }
    case "account/login/cancel":
      if mode == .lateCompletionAfterCancel {
        enqueue(
          json: """
            {"id":\(requestID),"result":{}}
            {"method":"account/login/completed","params":{"loginId":"login-7","success":true}}
            """
        )
      } else {
        enqueue(
          json: """
            {"id":\(requestID),"result":{}}
            """
        )
      }
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
    case "model/list":
      switch mode {
      case .modelCatalogSingle:
        enqueue(
          json: #"""
            {"id":2,"result":{"data":[{"id":" visible-model ","model":" visible-model ","displayName":" Visible Model ","description":" A visible model ","hidden":false,"defaultReasoningEffort":" medium ","supportedReasoningEfforts":[{"reasoningEffort":" low ","description":" quick "},{"effort":" high "}],"inputModalities":[" text "," "],"isDefault":true,"upgrade":" pro "},{"id":"hidden-model","hidden":true}],"nextCursor":" "}}
            """#)
      case .modelCatalogPagination:
        if object["params"]?["cursor"]?.stringValue == nil {
          enqueue(
            json: #"""
              {"id":2,"result":{"data":[{"id":" page-one-model ","model":" page-one-model ","displayName":"Page One"},{"id":"hidden-model","hidden":true},{"id":"page-one-model","model":"page-one-model"}],"nextCursor":" page-two "}}
              """#)
        } else {
          enqueue(
            json: #"""
              {"id":3,"result":{"data":[{"id":"page-two-model","model":"page-two-model","displayName":"Page Two"}],"nextCursor":" "}}
              """#)
        }
      case .modelCatalogLoop:
        if object["params"]?["cursor"]?.stringValue == nil {
          enqueue(
            json: #"""
              {"id":2,"result":{"data":[{"id":"loop-one","model":"loop-one"}],"nextCursor":" loop "}}
              """#)
        } else {
          enqueue(
            json: #"""
              {"id":3,"result":{"data":[{"id":"loop-two","model":"loop-two"}],"nextCursor":" loop "}}
              """#)
        }
      case .modelCatalogInvalid:
        enqueue(
          json: #"""
            {"id":2,"result":{"data":{"not":"an array"}}}
            """#)
      default:
        break
      }
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
      case .dynamicTool:
        enqueue(
          json: #"""
            {"id":3,"result":{"turn":{"id":"turn-1"}}}
            {"id":91,"method":"item/tool/call","params":{"threadId":"thread-1","turnId":"turn-1","callId":"dynamic-call-1","tool":"createDraft","arguments":{"value":"Codex 动态文章"}}}
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

  func sentMessageCount(method: String) -> Int {
    messages.reduce(into: 0) { count, message in
      if message["method"]?.stringValue == method {
        count += 1
      }
    }
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

private final class SequencedCodexTransportFactory: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0

  var makeCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return count
  }

  func make() -> any CodexAppServerTransport {
    lock.lock()
    count += 1
    let generation = count
    lock.unlock()
    return ScriptedCodexTransport(mode: generation == 1 ? .eofAfterHandshake : .account)
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
