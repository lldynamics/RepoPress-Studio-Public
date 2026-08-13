import Foundation
import XCTest

@testable import PublishingWorkbenchCore

final class AIOutboundPayloadPrivacyServiceTests: XCTestCase {
  func testCredentialVariantsRemoveCompleteSensitiveValuesWithoutOvermatchingOrdinaryText() throws {
    let cases: [(input: String, secret: String)] = [
      ("Authorization: Bearer secret-token", "secret-token"),
      ("authorization=Bearer second-secret", "second-secret"),
      ("Authorization: Basic basic-secret", "basic-secret"),
      ("Authorization   :    Token token-secret", "token-secret"),
      ("Proxy-Authorization: Basic proxy-secret", "proxy-secret"),
      ("  Proxy-Authorization   =    Token spaced-secret  ", "spaced-secret"),
      ("Bearer naked-secret", "naked-secret"),
      ("OPENAI_API_KEY=key-one", "key-one"),
      ("deepseek_api_key = 'key two'", "key two"),
      ("MY_CUSTOM_API_KEY=\"key-three\"", "key-three"),
      (#"{"api_key":"json-secret"}"#, "json-secret"),
      (#"{"access_token" : "access-secret"}"#, "access-secret"),
      ("password: password-value", "password-value"),
      ("token=query-like-value", "query-like-value"),
      ("AuThOrIzAtIoN : BeArEr \"mixed case secret\"", "mixed case secret"),
    ]
    let service = AIOutboundPayloadPrivacyService()

    for testCase in cases {
      let prepared = service.prepare(descriptor(text: testCase.input))
      let encodedMessages = try JSONEncoder().encode(prepared.messages)
      let messageJSON = try XCTUnwrap(String(data: encodedMessages, encoding: .utf8))
      let previewJSON = try XCTUnwrap(
        String(data: JSONEncoder().encode(prepared.preview), encoding: .utf8)
      )

      XCTAssertFalse(messageJSON.contains(testCase.secret), testCase.input)
      XCTAssertFalse(previewJSON.contains(testCase.secret), testCase.input)
      XCTAssertTrue(prepared.preview.strippedFields.contains(.credentialLikeSecret))
      XCTAssertTrue(prepared.preview.sensitiveCategories.contains(.credentialLikeSecret))
    }

    let ordinary = "Token budget is 4096; keep content/posts/token-guide.md as a relative path."
    let ordinaryResult = service.sanitize(ordinary)
    XCTAssertEqual(ordinaryResult.text, ordinary)
    XCTAssertFalse(ordinaryResult.strippedFields.contains(.credentialLikeSecret))
  }

  func testPreparedMessagesStripAbsolutePathsUsernameAndCommandsButKeepRelativePaths() throws {
    let service = AIOutboundPayloadPrivacyService()
    let prepared = service.prepare(
      descriptor(
        text: """
          请检查 /Users/alice/Projects/RepoPress/content/post.md
          保留 content/post.md
          预览命令：zola serve --root /Users/alice/Projects/RepoPress
          swift build --package-path /Users/alice/Projects/RepoPress
          """
      )
    )

    let encodedMessages = try JSONEncoder().encode(prepared.messages)
    let requestText = try XCTUnwrap(String(data: encodedMessages, encoding: .utf8))
    XCTAssertFalse(requestText.contains("/Users/"))
    XCTAssertFalse(requestText.contains("alice"))
    XCTAssertFalse(requestText.contains("zola serve"))
    XCTAssertFalse(requestText.contains("swift build"))
    guard case .text(let sanitizedText) = prepared.messages.first?.content else {
      return XCTFail("Expected sanitized text payload")
    }
    XCTAssertTrue(sanitizedText.contains("content/post.md"))
    XCTAssertTrue(prepared.preview.strippedFields.contains(.absoluteLocalPath))
    XCTAssertTrue(prepared.preview.strippedFields.contains(.homeUsername))
    XCTAssertTrue(prepared.preview.strippedFields.contains(.previewCommand))
    XCTAssertTrue(prepared.preview.strippedFields.contains(.buildCommand))
  }

  func testEachSelectedContextProducesOnlyItsDeclaredCategory() {
    let service = AIOutboundPayloadPrivacyService()
    let selectable = AIOutboundPayloadContextCategory.allCases.filter {
      $0 != .conversationHistory && $0 != .imageAttachment
    }

    for category in selectable {
      let prepared = service.prepare(
        AIOutboundPayloadDescriptor(
          endpoint: endpoint("/v1/chat/completions"),
          model: "model-a",
          messages: [AIChatMessage(role: "user", content: "hello")],
          contextCounts: [AIOutboundPayloadContextCount(category: category, count: 1)]
        )
      )
      let explicit = prepared.preview.contextCounts.filter {
        $0.category != .conversationHistory && $0.category != .imageAttachment
      }
      XCTAssertEqual(explicit, [AIOutboundPayloadContextCount(category: category, count: 1)])
    }
  }

  func testUnconfirmedCancelledExpiredAndDriftedPayloadsNeverReachTransport() async throws {
    let service = AIOutboundPayloadPrivacyService(confirmationLifetime: 30)
    let clock = Date(timeIntervalSince1970: 2_000)
    let prepared = service.prepare(descriptor(text: "hello"), now: clock)
    let transport = PrivacyGateRecordingTransport()

    await attemptTransport(
      prepared: prepared,
      confirmation: nil,
      service: service,
      now: clock,
      transport: transport
    )
    // Cancellation deliberately supplies no confirmation.
    await attemptTransport(
      prepared: prepared,
      confirmation: nil,
      service: service,
      now: clock,
      transport: transport
    )
    await attemptTransport(
      prepared: prepared,
      confirmation: AIOutboundPayloadConfirmation(preview: prepared.preview, confirmedAt: clock),
      service: service,
      now: clock.addingTimeInterval(31),
      transport: transport
    )

    let drifted = service.prepare(
      descriptor(text: "changed message"),
      now: clock,
      nonce: prepared.preview.nonce
    )
    await attemptTransport(
      prepared: drifted,
      confirmation: AIOutboundPayloadConfirmation(preview: prepared.preview, confirmedAt: clock),
      service: service,
      now: clock,
      transport: transport
    )

    let rejectedRequestCount = await transport.count()
    XCTAssertEqual(rejectedRequestCount, 0)
  }

  func testConfirmedUnchangedPayloadReachesTransportExactlyOnce() async throws {
    let service = AIOutboundPayloadPrivacyService()
    let now = Date(timeIntervalSince1970: 3_000)
    let prepared = service.prepare(descriptor(text: "hello"), now: now)
    let transport = PrivacyGateRecordingTransport()

    await attemptTransport(
      prepared: prepared,
      confirmation: AIOutboundPayloadConfirmation(preview: prepared.preview, confirmedAt: now),
      service: service,
      now: now,
      transport: transport
    )

    let confirmedRequestCount = await transport.count()
    XCTAssertEqual(confirmedRequestCount, 1)
  }

  @MainActor
  func testTransportAuthorizationRechecksExpiryAndCanBeConsumedOnlyOnce() throws {
    let service = AIOutboundPayloadPrivacyService(confirmationLifetime: 30)
    let now = Date(timeIntervalSince1970: 3_500)
    let prepared = service.prepare(descriptor(text: "one attempt"), now: now)
    let confirmation = AIOutboundPayloadConfirmation(preview: prepared.preview, confirmedAt: now)
    let authorization = AIOutboundPayloadTransportAuthorization(
      confirmation: confirmation,
      prepared: prepared,
      privacyService: service
    )

    XCTAssertNoThrow(try authorization.consume(now: now.addingTimeInterval(1)))
    XCTAssertThrowsError(try authorization.consume(now: now.addingTimeInterval(2))) { error in
      XCTAssertEqual(error as? AIOutboundPayloadConfirmationError, .alreadyConsumed)
    }

    let expiredAuthorization = AIOutboundPayloadTransportAuthorization(
      confirmation: confirmation,
      prepared: prepared,
      privacyService: service
    )
    XCTAssertThrowsError(
      try expiredAuthorization.consume(now: now.addingTimeInterval(31))
    ) { error in
      XCTAssertEqual(error as? AIOutboundPayloadConfirmationError, .expired)
    }
  }

  func testEndpointPathChangeInvalidatesConfirmationAndDestinationDropsSecrets() throws {
    let service = AIOutboundPayloadPrivacyService()
    let now = Date(timeIntervalSince1970: 4_000)
    let nonce = UUID()
    let original = service.prepare(
      AIOutboundPayloadDescriptor(
        endpoint: URL(
          string: "https://user:password@example.com:8443/v1/chat/completions?key=secret#fragment"
        )!,
        model: "model-a",
        messages: [AIChatMessage(role: "user", content: "hello")]
      ),
      now: now,
      nonce: nonce
    )
    let changed = service.prepare(
      AIOutboundPayloadDescriptor(
        endpoint: endpoint("/v2/chat/completions"),
        model: "model-a",
        messages: [AIChatMessage(role: "user", content: "hello")]
      ),
      now: now,
      nonce: nonce
    )

    XCTAssertEqual(original.preview.destination, "https://example.com:8443/v1/chat/completions")
    XCTAssertFalse(original.preview.destination.contains("password"))
    XCTAssertFalse(original.preview.destination.contains("secret"))
    XCTAssertThrowsError(
      try service.validate(
        confirmation: AIOutboundPayloadConfirmation(preview: original.preview, confirmedAt: now),
        prepared: changed,
        now: now
      )
    ) { error in
      XCTAssertEqual(error as? AIOutboundPayloadConfirmationError, .drifted)
    }
  }

  func testContextIdentityChangeInvalidatesConfirmationEvenWhenPayloadTextMatches() throws {
    let service = AIOutboundPayloadPrivacyService()
    let now = Date(timeIntervalSince1970: 4_500)
    let nonce = UUID()
    let original = service.prepare(
      AIOutboundPayloadDescriptor(
        endpoint: endpoint("/v1/chat/completions"),
        model: "model-a",
        messages: [AIChatMessage(role: "user", content: "same resolved text")],
        contextCounts: [.init(category: .specifiedArticle, count: 1)],
        contextBindingValues: ["specifiedArticle|article-a"]
      ),
      now: now,
      nonce: nonce
    )
    let changed = service.prepare(
      AIOutboundPayloadDescriptor(
        endpoint: endpoint("/v1/chat/completions"),
        model: "model-a",
        messages: [AIChatMessage(role: "user", content: "same resolved text")],
        contextCounts: [.init(category: .specifiedArticle, count: 1)],
        contextBindingValues: ["specifiedArticle|article-b"]
      ),
      now: now,
      nonce: nonce
    )

    XCTAssertThrowsError(
      try service.validate(
        confirmation: AIOutboundPayloadConfirmation(preview: original.preview, confirmedAt: now),
        prepared: changed,
        now: now
      )
    ) { error in
      XCTAssertEqual(error as? AIOutboundPayloadConfirmationError, .drifted)
    }
  }

  func testImagesAreSummarizedWithoutContentAndImageChangeInvalidatesFingerprint() throws {
    let service = AIOutboundPayloadPrivacyService()
    let now = Date(timeIntervalSince1970: 5_000)
    let nonce = UUID()
    let first = service.prepare(
      descriptor(text: "caption", imageData: Data([1, 2, 3, 4])),
      now: now,
      nonce: nonce
    )
    let changed = service.prepare(
      descriptor(text: "caption", imageData: Data([1, 2, 3, 5])),
      now: now,
      nonce: nonce
    )

    XCTAssertEqual(first.preview.imageCount, 1)
    XCTAssertEqual(first.preview.imageByteCount, 4)
    XCTAssertNotEqual(first.preview.fingerprint, changed.preview.fingerprint)
    XCTAssertThrowsError(
      try service.validate(
        confirmation: AIOutboundPayloadConfirmation(preview: first.preview, confirmedAt: now),
        prepared: changed,
        now: now
      )
    )
  }

  func testPreviewCodableContainsNoBodyRawPathKeyOrImageContent() throws {
    let service = AIOutboundPayloadPrivacyService()
    let prepared = service.prepare(
      descriptor(
        text: "secret body /Users/alice/private.md API_KEY=do-not-store",
        imageData: Data("secret image bytes".utf8)
      )
    )

    let data = try JSONEncoder().encode(prepared.preview)
    let json = try XCTUnwrap(String(data: data, encoding: .utf8))
    XCTAssertFalse(json.contains("secret body"))
    XCTAssertFalse(json.contains("/Users/"))
    XCTAssertFalse(json.contains("alice"))
    XCTAssertFalse(json.contains("do-not-store"))
    XCTAssertFalse(json.contains("secret image bytes"))
    XCTAssertFalse(json.contains("data:image"))
    XCTAssertNoThrow(try JSONDecoder().decode(AIOutboundPayloadPreview.self, from: data))
  }

  @MainActor
  func testRemoteBrokerAutomaticallyAuthorizesWithoutPendingContinuationAndKeepsScopeIsolation()
    async throws
  {
    let broker = AIOutboundPayloadApprovalBroker()
    let service = AIOutboundPayloadPrivacyService()
    let previewA = service.prepare(descriptor(text: "request-a")).preview
    let previewB = service.prepare(descriptor(text: "request-b")).preview
    let scopeA = UUID()
    let scopeB = UUID()

    let taskA = Task { await broker.requestApproval(for: previewA, scopeID: scopeA) }
    let taskB = Task { await broker.requestApproval(for: previewB, scopeID: scopeB) }
    guard case .confirmed(let confirmationA) = await taskA.value else {
      return XCTFail("Request A should be confirmed independently")
    }
    guard case .confirmed(let confirmationB) = await taskB.value else {
      return XCTFail("Request B should be confirmed independently")
    }

    XCTAssertEqual(confirmationA.fingerprint, previewA.fingerprint)
    XCTAssertEqual(confirmationB.fingerprint, previewB.fingerprint)
    XCTAssertNotEqual(confirmationA.fingerprint, confirmationB.fingerprint)

    XCTAssertNil(broker.pendingRequest(for: scopeA))
    XCTAssertNil(broker.pendingRequest(for: scopeB))
    XCTAssertEqual(broker.pendingRequestCountForTesting, 0)
    XCTAssertEqual(broker.continuationCountForTesting, 0)
    XCTAssertEqual(broker.lastPreview(for: scopeA), previewA)
    XCTAssertEqual(broker.lastPreview(for: scopeB), previewB)
    XCTAssertNotEqual(broker.lastPreview(for: scopeA), broker.lastPreview(for: scopeB))
  }

  @MainActor
  func testTestingDecisionProviderCanCancelWithoutCreatingPendingState() async throws {
    let broker = AIOutboundPayloadApprovalBroker()
    let service = AIOutboundPayloadPrivacyService()
    let scopeID = UUID()

    broker.testingDecisionProvider = { _ in .cancel }
    defer { broker.testingDecisionProvider = nil }
    let preview = service.prepare(descriptor(text: "cancelled by test")).preview
    let outcome = await broker.requestApproval(for: preview, scopeID: scopeID)
    guard case .cancelled = outcome else {
      return XCTFail("The injected testing decision should cancel the request")
    }

    XCTAssertNil(broker.pendingRequest(for: scopeID))
    XCTAssertEqual(broker.pendingRequestCountForTesting, 0)
    XCTAssertEqual(broker.continuationCountForTesting, 0)
    XCTAssertEqual(broker.lastPreview(for: scopeID), preview)
  }

  private func descriptor(
    text: String,
    imageData: Data? = nil
  ) -> AIOutboundPayloadDescriptor {
    let content: AIChatMessageContent
    if let imageData {
      content = .parts([
        .text(text),
        .imageURL("data:image/png;base64,\(imageData.base64EncodedString())"),
      ])
    } else {
      content = .text(text)
    }
    return AIOutboundPayloadDescriptor(
      endpoint: endpoint("/v1/chat/completions"),
      model: "model-a",
      messages: [AIChatMessage(role: "user", content: content)]
    )
  }

  private func endpoint(_ path: String) -> URL {
    URL(string: "https://example.com\(path)")!
  }

  private func attemptTransport(
    prepared: AIPreparedOutboundPayload,
    confirmation: AIOutboundPayloadConfirmation?,
    service: AIOutboundPayloadPrivacyService,
    now: Date,
    transport: PrivacyGateRecordingTransport
  ) async {
    do {
      try service.validate(confirmation: confirmation, prepared: prepared, now: now)
      await transport.record()
    } catch {
      // A rejected gate intentionally performs no transport operation.
    }
  }
}

private actor PrivacyGateRecordingTransport {
  private var requestCount = 0

  func record() {
    requestCount += 1
  }

  func count() -> Int {
    requestCount
  }
}
