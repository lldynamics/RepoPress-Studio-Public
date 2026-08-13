import Foundation
import XCTest

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

    let report = await store.testAIConnection(probeCapabilities: [.chat])

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
      await store.testAIConnection(probeCapabilities: [.chat])
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

    let report = await store.testAIConnection(probeCapabilities: [.chat])

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
