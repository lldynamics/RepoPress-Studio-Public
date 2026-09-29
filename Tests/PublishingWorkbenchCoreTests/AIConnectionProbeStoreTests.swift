import Foundation
import XCTest

@testable import PublishingAICore
@testable import PublishingWorkbenchCore

@MainActor
final class AIConnectionProbeStoreTests: XCTestCase {
  func testSelectedChatProbeReusesPingAndPersistsCurrentEvidence() async throws {
    let persistenceURL = try temporaryPersistenceURL()
    defer { try? FileManager.default.removeItem(at: persistenceURL.deletingLastPathComponent()) }
    let (consentStore, defaults, suiteName) = makeIsolatedConsentStore()
    defer {
      defaults.removePersistentDomain(forName: suiteName)
    }
    let transport = RecordingAIChatTransport(
      data: responseData,
      statusCode: 200
    )
    let store = makeStore(
      persistenceURL: persistenceURL,
      transport: transport,
      consentStore: consentStore
    )
    configure(store)
    XCTAssertTrue(consentStore.grant(for: store.activeAIConnectionProfile.config))

    let report = await store.aiStore.testAIConnection(probeCapabilities: [.chat])

    XCTAssertEqual(report?.capabilityProbeReport?.results[.chat]?.outcome, .supported)
    let requestCount = await transport.capturedRequestCount()
    XCTAssertEqual(requestCount, 1)
    XCTAssertEqual(
      store.activeAIConnectionProfile.config.capabilityEvidenceState(for: .chat),
      .probed
    )
    XCTAssertEqual(
      store.activeAIConnectionProfile.config.capabilityProbeEvidence?[.chat]?.outcome,
      .supported
    )
    await store.waitForPendingSave()

    let restoredStore = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: persistenceURL),
      safeMode: true,
      keychainTokenStore: testTokenStore()
    )
    XCTAssertEqual(
      restoredStore.activeAIConnectionProfile.config.capabilityEvidenceState(for: .chat),
      .probed
    )
  }

  func testProbeEvidenceIsNotPersistedAfterConnectionIdentityDrifts() async throws {
    let persistenceURL = try temporaryPersistenceURL()
    defer { try? FileManager.default.removeItem(at: persistenceURL.deletingLastPathComponent()) }
    let (consentStore, defaults, suiteName) = makeIsolatedConsentStore()
    defer {
      defaults.removePersistentDomain(forName: suiteName)
    }
    let transport = GatedAIChatTransport(data: responseData, statusCode: 200)
    let store = makeStore(
      persistenceURL: persistenceURL,
      transport: transport,
      consentStore: consentStore
    )
    configure(store)
    XCTAssertTrue(consentStore.grant(for: store.activeAIConnectionProfile.config))

    let testTask = Task { @MainActor in
      await store.aiStore.testAIConnection(probeCapabilities: [.chat])
    }
    await transport.waitForRequest()

    var driftedConnection = store.activeAIConnectionProfile
    driftedConnection.config.model = "drifted-model"
    XCTAssertTrue(store.updateAIConnectionProfile(driftedConnection))
    await transport.release()
    _ = await testTask.value

    XCTAssertNil(store.activeAIConnectionProfile.config.capabilityProbeEvidence)
  }

  func testRemoteConnectionProbeWithoutConsentDoesNotTransport() async throws {
    let persistenceURL = try temporaryPersistenceURL()
    defer { try? FileManager.default.removeItem(at: persistenceURL.deletingLastPathComponent()) }
    let (consentStore, defaults, suiteName) = makeIsolatedConsentStore()
    defer {
      defaults.removePersistentDomain(forName: suiteName)
    }
    let transport = RecordingAIChatTransport(data: responseData, statusCode: 200)
    let store = makeStore(
      persistenceURL: persistenceURL,
      transport: transport,
      consentStore: consentStore
    )
    configure(store)

    let report = await store.aiStore.testAIConnection(probeCapabilities: [.chat])

    XCTAssertNil(report)
    let requestCount = await transport.capturedRequestCount()
    XCTAssertEqual(requestCount, 0)
  }

  private var responseData: Data {
    Data(
      """
      {
        "model": "fixture-model",
        "choices": [{"message":{"role":"assistant","content":"OK"}}]
      }
      """.utf8)
  }

  private func makeStore(
    persistenceURL: URL,
    transport: any AIChatTransport,
    consentStore: AIDataSharingConsentStore
  ) -> WorkbenchStore {
    WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: persistenceURL),
      safeMode: true,
      keychainTokenStore: testTokenStore(),
      aiConnectionTestService: AIConnectionTestService(
        client: AIChatCompletionClient(transport: transport)
      ),
      aiDataSharingConsentStore: consentStore
    )
  }

  private func configure(_ store: WorkbenchStore) {
    var connection = store.activeAIConnectionProfile
    connection.config = AIProviderConfig(
      preset: .custom,
      baseURL: "https://example.com/v1",
      model: "fixture-model",
      requiresAPIKey: false
    )
    XCTAssertTrue(store.updateAIConnectionProfile(connection))
  }

  private func testTokenStore() -> KeychainTokenStore {
    KeychainTokenStore(
      service: "AIConnectionProbeStoreTests.\(UUID().uuidString)",
      accountPrefix: "ai-connection-probe-store-tests",
      inMemory: true
    )
  }

  private func temporaryPersistenceURL() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("AIConnectionProbeStoreTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("workbench.json")
  }

  private func makeIsolatedConsentStore() -> (
    AIDataSharingConsentStore,
    UserDefaults,
    String
  ) {
    let suiteName = "AIConnectionProbeStoreTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    return (
      AIDataSharingConsentStore(defaults: defaults),
      defaults,
      suiteName
    )
  }
}

actor GatedAIChatTransport: AIChatTransport, AIChatStreamingTransport {
  private let data: Data
  private let statusCode: Int
  private var released = false
  private var requestCount = 0

  init(data: Data, statusCode: Int) {
    self.data = data
    self.statusCode = statusCode
  }

  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    requestCount += 1
    while !released {
      try await Task.sleep(nanoseconds: 1_000_000)
    }
    return (data, response(for: request))
  }

  func lines(for request: URLRequest) async throws -> (
    AsyncThrowingStream<String, Error>, URLResponse
  ) {
    requestCount += 1
    return (AsyncThrowingStream { $0.finish() }, response(for: request))
  }

  func waitForRequest() async {
    for _ in 0..<100 {
      if requestCount > 0 { return }
      try? await Task.sleep(nanoseconds: 1_000_000)
    }
  }

  func release() {
    released = true
  }

  private func response(for request: URLRequest) -> HTTPURLResponse {
    HTTPURLResponse(
      url: request.url!,
      statusCode: statusCode,
      httpVersion: nil,
      headerFields: nil
    )!
  }
}

@MainActor
final class AIConnectionManagementTests: XCTestCase {
  func testNonActiveCredentialOperationsStayOnTheRequestedConnection() throws {
    let (store, tokens, cleanup) = try makeStore()
    defer { cleanup() }
    let activeID = store.activeAIConnectionProfile.id
    var active = store.activeAIConnectionProfile
    active.config = configuredProvider(
      baseURL: "https://active.example/v1", model: "active-model", requiresAPIKey: true)
    XCTAssertTrue(store.updateAIConnectionProfile(active))
    let activeSite = store.activeProfile
    XCTAssertTrue(store.ai.saveAPIKey("active-secret", connectionProfileID: activeID))

    let secondary = makeConnection(
      in: store, name: "Secondary", baseURL: "https://secondary.example/v1")
    XCTAssertTrue(store.ai.saveAPIKey("secondary-secret", connectionProfileID: secondary.id))
    XCTAssertEqual(try tokens.aiToken(forConnectionProfileID: activeID), "active-secret")
    XCTAssertEqual(try tokens.aiToken(forConnectionProfileID: secondary.id), "secondary-secret")
    XCTAssertEqual(store.activeAIConnectionProfile.id, activeID)
    XCTAssertEqual(store.activeProfile, activeSite)

    store.ai.deleteAPIKey(connectionProfileID: secondary.id)
    XCTAssertNil(try tokens.aiToken(forConnectionProfileID: secondary.id))
    XCTAssertEqual(try tokens.aiToken(forConnectionProfileID: activeID), "active-secret")
    XCTAssertEqual(store.activeProfile, activeSite)

    let unknownID = UUID()
    XCTAssertFalse(store.ai.saveAPIKey("unknown-secret", connectionProfileID: unknownID))
    store.ai.deleteAPIKey(connectionProfileID: unknownID)
    XCTAssertNil(try tokens.aiToken(forConnectionProfileID: unknownID))
    XCTAssertEqual(try tokens.aiToken(forConnectionProfileID: activeID), "active-secret")
  }

  func testDuplicateConnectionDoesNotBindSiteOrCopyCredentials() throws {
    let (store, tokens, cleanup) = try makeStore()
    defer { cleanup() }
    let original = makeConnection(
      in: store, name: "Original", baseURL: "https://duplicate.example/v1")
    XCTAssertTrue(store.ai.saveAPIKey("original-secret", connectionProfileID: original.id))
    let siteBefore = store.activeProfile
    let copy = try XCTUnwrap(store.duplicateAIConnectionProfile(original.id))

    XCTAssertNotEqual(copy.id, original.id)
    XCTAssertEqual(store.activeProfile, siteBefore)
    XCTAssertNotEqual(store.activeAIConnectionProfile.id, copy.id)
    XCTAssertNil(try tokens.aiToken(forConnectionProfileID: copy.id))
    XCTAssertEqual(try tokens.aiToken(forConnectionProfileID: original.id), "original-secret")
    XCTAssertFalse(copy.canUseLegacyCredentials)
  }

  func testConnectionTestTargetsRequestedNonActiveConnectionAndPersistsEvidence() async throws {
    let transport = RecordingAIChatTransport(
      data: Data(
        "{\"model\":\"target-model\",\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"OK\"}}]}"
          .utf8),
      statusCode: 200
    )
    let (consentStore, defaults, suiteName) = makeIsolatedConsentStore()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let (store, _, cleanup) = try makeStore(transport: transport, consentStore: consentStore)
    defer { cleanup() }
    let activeID = store.activeAIConnectionProfile.id
    let target = makeConnection(
      in: store,
      name: "Probe target",
      baseURL: "https://probe-target.example/v1",
      requiresAPIKey: false
    )
    XCTAssertTrue(consentStore.grant(for: target.config))

    let report = await store.ai.testConnection(
      connectionProfileID: target.id,
      probeCapabilities: [.chat]
    )

    XCTAssertEqual(report?.capabilityProbeReport?.results[.chat]?.outcome, .supported)
    let requestCount = await transport.capturedRequestCount()
    XCTAssertEqual(requestCount, 1)
    XCTAssertEqual(store.activeAIConnectionProfile.id, activeID)
    XCTAssertEqual(
      store.aiConnectionProfile(for: target.id)?.config.capabilityEvidenceState(for: .chat),
      .probed
    )
    XCTAssertEqual(
      store.aiConnectionProfile(for: target.id)?.config.capabilityProbeEvidence?[.chat]?.outcome,
      .supported
    )
  }

  func testConsentRevocationTargetsOnlyRequestedConnection() throws {
    let (consentStore, defaults, suiteName) = makeIsolatedConsentStore()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let (store, _, cleanup) = try makeStore(consentStore: consentStore)
    defer { cleanup() }
    var active = store.activeAIConnectionProfile
    active.config = configuredProvider(
      baseURL: "https://consent-active.example/v1", model: "active-model", requiresAPIKey: false)
    XCTAssertTrue(store.updateAIConnectionProfile(active))
    let target = makeConnection(
      in: store, name: "Consent target", baseURL: "https://consent-target.example/v1")
    XCTAssertTrue(consentStore.grant(for: active.config))
    XCTAssertTrue(consentStore.grant(for: target.config))

    store.ai.revokeDataSharingConsent(connectionProfileID: target.id)

    XCTAssertTrue(consentStore.presentation(for: active.config).isGranted)
    XCTAssertFalse(consentStore.presentation(for: target.config).isGranted)
  }

  func testInactiveLegacyConnectionUsesItsSingleMatchingSiteOwner() throws {
    let (store, tokens, cleanup) = try makeStore()
    defer { cleanup() }
    let connection = makeLegacyConnection(
      in: store, name: "Legacy owner", baseURL: "https://legacy-owner.example/v1")
    var owner = store.activeProfile
    owner.id = UUID()
    owner.name = "Legacy owner site"
    owner.aiConnectionProfileID = nil
    owner.aiProviderConfig = connection.config
    let unboundOwner = owner
    try tokens.saveAIToken("legacy-owner-key", for: unboundOwner)
    owner.aiConnectionProfileID = connection.id
    store.setProfiles([store.activeProfile, owner])
    let legacyConnection = try XCTUnwrap(store.aiConnectionProfile(for: connection.id))
    XCTAssertTrue(legacyConnection.canUseLegacyCredentials)
    XCTAssertTrue(store.aiStore.aiDataSharingConsentStore.grant(for: legacyConnection.config))

    XCTAssertEqual(try store.aiStore.settingsAPIKey(for: legacyConnection), "legacy-owner-key")
    XCTAssertEqual(try tokens.aiToken(for: unboundOwner), "legacy-owner-key")
    XCTAssertNil(try tokens.aiToken(forConnectionProfileID: connection.id))
    XCTAssertNotEqual(store.activeProfile.id, owner.id)
  }

  func testInactiveLegacyConnectionWithAmbiguousSiteOwnersUsesProfileCredential() throws {
    let (store, tokens, cleanup) = try makeStore()
    defer { cleanup() }
    let connection = makeLegacyConnection(
      in: store, name: "Ambiguous legacy", baseURL: "https://ambiguous-legacy.example/v1")
    var firstOwner = store.activeProfile
    firstOwner.id = UUID()
    firstOwner.name = "First owner"
    firstOwner.aiConnectionProfileID = nil
    firstOwner.aiProviderConfig = connection.config
    let unboundFirstOwner = firstOwner
    try tokens.saveAIToken("legacy-first-key", for: unboundFirstOwner)
    firstOwner.aiConnectionProfileID = connection.id
    var secondOwner = firstOwner
    secondOwner.id = UUID()
    secondOwner.name = "Second owner"
    store.setProfiles([store.activeProfile, firstOwner, secondOwner])
    let legacyConnection = try XCTUnwrap(store.aiConnectionProfile(for: connection.id))
    XCTAssertTrue(legacyConnection.canUseLegacyCredentials)
    XCTAssertTrue(store.aiStore.aiDataSharingConsentStore.grant(for: legacyConnection.config))

    XCTAssertThrowsError(try store.aiStore.settingsAPIKey(for: legacyConnection)) { error in
      guard let failure = error as? AIPublishingAssistantError,
        case .missingAPIKey = failure
      else { return XCTFail("Ambiguous legacy owners must require a connection key: \(error)") }
    }
    XCTAssertTrue(store.ai.saveAPIKey("profile-key", connectionProfileID: connection.id))
    XCTAssertEqual(try store.aiStore.settingsAPIKey(for: legacyConnection), "profile-key")
    XCTAssertEqual(try tokens.aiToken(for: unboundFirstOwner), "legacy-first-key")
    XCTAssertEqual(try tokens.aiToken(forConnectionProfileID: connection.id), "profile-key")
  }

  func testModelDiscoveryWithoutConsentDoesNotReadKeyOrSendRequest() async throws {
    let (store, _, cleanup) = try makeStore()
    defer { cleanup() }
    let target = makeConnection(
      in: store, name: "No consent", baseURL: "https://unapproved.example/v1"
    )
    let transport = AIConnectionManagementModelDiscoveryTransport(
      data: Data(),
      response: HTTPURLResponse(
        url: URL(string: "https://unapproved.example/v1/models")!,
        statusCode: 200, httpVersion: nil, headerFields: nil
      )!
    )
    do {
      _ = try await store.aiStore.discoverAIModels(
        forConnectionProfileID: target.id, requestedConfig: target.config,
        service: AIModelDiscoveryService(transport: transport)
      )
      XCTFail("Unapproved discovery must fail before resolving a key or sending a request")
    } catch {
      XCTAssertEqual(error as? AIModelDiscoveryError, .authorizationChanged)
    }
    let recordedRequest = await transport.lastRequest
    XCTAssertNil(recordedRequest)
  }

  func testModelDiscoveryUsesRequestedInactiveConnectionWithoutChangingSite() async throws {
    let (store, tokens, cleanup) = try makeStore()
    defer { cleanup() }
    let activeID = store.activeAIConnectionProfile.id
    let activeSiteID = store.activeProfile.id
    let target = makeConnection(
      in: store, name: "Discovery target", baseURL: "https://discovery-target.example/v1")
    XCTAssertTrue(store.ai.saveAPIKey("discovery-key", connectionProfileID: target.id))
    let consentStore = store.aiStore.aiDataSharingConsentStore
    XCTAssertTrue(consentStore.grant(for: target.config))
    let endpoint = URL(string: "https://discovery-target.example/v1/models")!
    let transport = AIConnectionManagementModelDiscoveryTransport(
      data: Data(#"{"data":[{"id":"target-model"}]}"#.utf8),
      response: HTTPURLResponse(
        url: endpoint,
        statusCode: 200,
        httpVersion: "HTTP/1.1",
        headerFields: nil
      )!
    )
    let service = AIModelDiscoveryService(transport: transport)

    let models = try await store.aiStore.discoverAIModels(
      forConnectionProfileID: target.id,
      requestedConfig: target.config,
      service: service
    )

    XCTAssertEqual(models.map(\.id), ["target-model"])
    XCTAssertEqual(store.activeAIConnectionProfile.id, activeID)
    XCTAssertEqual(store.activeProfile.id, activeSiteID)
    XCTAssertEqual(try tokens.aiToken(forConnectionProfileID: target.id), "discovery-key")
    let recordedRequest = await transport.lastRequest
    XCTAssertEqual(recordedRequest?.url?.absoluteString, endpoint.absoluteString)
  }

  /// Seed the state of an already-migrated legacy connection. Changing a new
  /// connection's endpoint would intentionally invalidate all old credentials.
  private func makeLegacyConnection(
    in store: WorkbenchStore, name: String, baseURL: String
  ) -> AIConnectionProfile {
    let connection = AIConnectionProfile(
      name: name,
      config: configuredProvider(baseURL: baseURL, model: "legacy", requiresAPIKey: true),
      allowsLegacyCredentialFallback: true
    )
    store.aiConnectionProfiles.append(connection)
    return connection
  }

  private func makeConnection(
    in store: WorkbenchStore,
    name: String,
    baseURL: String,
    requiresAPIKey: Bool = true
  ) -> AIConnectionProfile {
    var connection = store.createAIConnectionProfile(named: name, preset: .custom)
    connection.config = configuredProvider(
      baseURL: baseURL, model: "target-model", requiresAPIKey: requiresAPIKey)
    XCTAssertTrue(store.updateAIConnectionProfile(connection))
    return connection
  }

  private func configuredProvider(
    baseURL: String,
    model: String,
    requiresAPIKey: Bool
  ) -> AIProviderConfig {
    AIProviderConfig(
      preset: .custom,
      baseURL: baseURL,
      model: model,
      requiresAPIKey: requiresAPIKey
    )
  }

  private func makeStore(
    transport: (any AIChatTransport)? = nil,
    consentStore: AIDataSharingConsentStore? = nil
  ) throws -> (WorkbenchStore, KeychainTokenStore, () -> Void) {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("AIConnectionManagementTests-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let tokens = KeychainTokenStore(
      service: "AIConnectionManagementTests-\(UUID())",
      accountPrefix: "ai-connection-management-tests",
      inMemory: true
    )
    let suiteName = "AIConnectionManagementDefaults-\(UUID())"
    let defaults = UserDefaults(suiteName: suiteName)!
    let service =
      transport.map {
        AIConnectionTestService(client: AIChatCompletionClient(transport: $0))
      } ?? AIConnectionTestService()
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(
        fileURL: directory.appendingPathComponent("workbench.json")),
      safeMode: true,
      keychainTokenStore: tokens,
      aiConnectionTestService: service,
      aiDataSharingConsentStore: consentStore ?? AIDataSharingConsentStore(defaults: defaults)
    )
    return (
      store, tokens,
      {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
      }
    )
  }

  private func makeIsolatedConsentStore() -> (AIDataSharingConsentStore, UserDefaults, String) {
    let suiteName = "AIConnectionManagementTests-\(UUID())"
    let defaults = UserDefaults(suiteName: suiteName)!
    return (AIDataSharingConsentStore(defaults: defaults), defaults, suiteName)
  }
}

private actor AIConnectionManagementModelDiscoveryTransport: AIModelDiscoveryTransport {
  private let data: Data
  private let response: URLResponse
  private(set) var lastRequest: URLRequest?

  init(data: Data, response: URLResponse) {
    self.data = data
    self.response = response
  }

  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    lastRequest = request
    return (data, response)
  }
}
