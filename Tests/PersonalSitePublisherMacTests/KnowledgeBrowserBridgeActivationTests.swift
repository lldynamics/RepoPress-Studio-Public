import Foundation
import Network
import PublishingWorkbenchCore
import XCTest

@testable import PersonalSitePublisherMac

@MainActor
final class KnowledgeBrowserBridgeActivationTests: XCTestCase {
  func testBridgeAllocatesNetworkResourcesOnlyAfterEnableAndReleasesThemOnDisable() async throws {
    let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "knowledge-browser-lazy-network-\(UUID().uuidString)",
      isDirectory: true
    )
    let suiteName = "KnowledgeBrowserBridgeActivationTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    defer {
      defaults.removePersistentDomain(forName: suiteName)
      try? FileManager.default.removeItem(at: rootURL)
    }

    let bridge = KnowledgeBrowserBridge(
      knowledge: KnowledgeStore(
        service: KnowledgeLibraryService(
          rootURL: rootURL.appendingPathComponent("KnowledgeLibrary", isDirectory: true)
        )
      ),
      defaults: defaults,
      connectionTokenKeychainStore: KeychainTokenStore(
        service: KeychainCredentialServices.browserBridge,
        accountPrefix: "browser-lazy-network-test-\(UUID().uuidString)",
        inMemory: true,
        allowsAuthenticationInteraction: false
      ),
      // This test only observes the network lifetime. Keep the ledger in the
      // injected defaults rather than adding a second filesystem operation to
      // a shard that may be running alongside other integration tests.
      importOperationLedgerURL: nil,
      makeListener: { _ in
        try NWListener(using: .tcp, on: .any)
      }
    )

    bridge.start()

    XCTAssertFalse(bridge.isEnabled)
    XCTAssertFalse(bridge.hasAllocatedNetworkResources)
    XCTAssertEqual(bridge.activeNetworkConnectionCount, 0)

    bridge.setEnabled(true)
    guard
      try await waitUntil(condition: {
        bridge.state == .ready && bridge.activeListenerPort != nil
      })
    else {
      XCTFail(
        "Browser bridge did not become ready (state: \(bridge.state), "
          + "resources: \(bridge.hasAllocatedNetworkResources), "
          + "port: \(String(describing: bridge.activeListenerPort)))"
      )
      return
    }
    XCTAssertTrue(bridge.hasAllocatedNetworkResources)

    let activePort = try XCTUnwrap(bridge.activeListenerPort)
    let port = try XCTUnwrap(NWEndpoint.Port(rawValue: activePort))
    let client = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
    client.start(queue: DispatchQueue(label: "KnowledgeBrowserBridgeActivationTests.client"))
    defer { client.cancel() }
    guard
      try await waitUntil(condition: {
        bridge.activeNetworkConnectionCount == 1
      })
    else {
      XCTFail(
        "Browser bridge did not observe the client connection (state: \(bridge.state), "
          + "resources: \(bridge.hasAllocatedNetworkResources), "
          + "connections: \(bridge.activeNetworkConnectionCount))"
      )
      return
    }

    bridge.setEnabled(false)

    XCTAssertFalse(bridge.isEnabled)
    XCTAssertEqual(bridge.state, .stopped)
    XCTAssertFalse(bridge.hasAllocatedNetworkResources)
    XCTAssertEqual(bridge.activeNetworkConnectionCount, 0)
  }

  func testDisabledBridgeDefersExistingKeychainTokenUntilUserEnablesIt() throws {
    let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "knowledge-browser-activation-\(UUID().uuidString)",
      isDirectory: true
    )
    let suiteName = "KnowledgeBrowserBridgeActivationTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    defer {
      defaults.removePersistentDomain(forName: suiteName)
      try? FileManager.default.removeItem(at: rootURL)
    }

    let keychain = KeychainTokenStore(
      service: KeychainCredentialServices.browserBridge,
      accountPrefix: "browser-activation-test-\(UUID().uuidString)",
      inMemory: true,
      allowsAuthenticationInteraction: false
    )
    let tokenStore = KnowledgeBrowserConnectionTokenStore(keychain: keychain)
    let existingToken = String(repeating: "a", count: 64)
    try tokenStore.persist(existingToken)

    let bridge = KnowledgeBrowserBridge(
      knowledge: KnowledgeStore(
        service: KnowledgeLibraryService(
          rootURL: rootURL.appendingPathComponent("KnowledgeLibrary", isDirectory: true)
        )
      ),
      defaults: defaults,
      connectionTokenKeychainStore: keychain,
      importOperationLedgerURL: rootURL.appendingPathComponent("import-ledger.plist")
    )

    XCTAssertFalse(bridge.isEnabled)
    XCTAssertTrue(bridge.connectionToken.isEmpty)
    XCTAssertEqual(try tokenStore.token(), existingToken)

    bridge.setEnabled(true)

    XCTAssertTrue(bridge.isEnabled)
    XCTAssertTrue(defaults.bool(forKey: "KnowledgeBrowserBridge.isEnabled.v1"))
    XCTAssertEqual(bridge.connectionToken, existingToken)

    bridge.setEnabled(false)

    XCTAssertFalse(bridge.isEnabled)
    XCTAssertFalse(defaults.bool(forKey: "KnowledgeBrowserBridge.isEnabled.v1"))
    XCTAssertTrue(bridge.connectionToken.isEmpty)
    XCTAssertEqual(try tokenStore.token(), existingToken)
  }

  func testUnknownApprovedRouteReturns404AfterAuthorization() async throws {
    let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "knowledge-browser-unknown-route-\(UUID().uuidString)",
      isDirectory: true
    )
    let suiteName = "KnowledgeBrowserBridgeUnknownRouteTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    defer {
      defaults.removePersistentDomain(forName: suiteName)
      try? FileManager.default.removeItem(at: rootURL)
    }

    let bridge = KnowledgeBrowserBridge(
      knowledge: KnowledgeStore(
        service: KnowledgeLibraryService(
          rootURL: rootURL.appendingPathComponent("KnowledgeLibrary", isDirectory: true)
        )
      ),
      defaults: defaults,
      connectionTokenKeychainStore: KeychainTokenStore(
        service: KeychainCredentialServices.browserBridge,
        accountPrefix: "browser-unknown-route-test-\(UUID().uuidString)",
        inMemory: true,
        allowsAuthenticationInteraction: false
      ),
      importOperationLedgerURL: nil,
      makeListener: { _ in
        try NWListener(using: .tcp, on: .any)
      }
    )
    defer { bridge.stop() }

    bridge.setEnabled(true)
    guard
      try await waitUntil(condition: {
        bridge.state == .ready && bridge.activeListenerPort != nil
      })
    else {
      return XCTFail("Browser bridge did not become ready for the route test")
    }

    let activePort = try XCTUnwrap(bridge.activeListenerPort)
    let port = try XCTUnwrap(NWEndpoint.Port(rawValue: activePort))
    let connection = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
    let responseExpectation = expectation(description: "unknown route response")
    let reader = BrowserBridgeTestResponseReader(
      connection: connection,
      completion: responseExpectation
    )
    let request = Data(
      [
        "GET /v1/unknown HTTP/1.1",
        "Host: 127.0.0.1:\(activePort)",
        "Origin: chrome-extension://lnibkmfhfikfbkeehcjbiaalhkiankam",
        "X-RepoPress-Protocol: 1",
        "Authorization: Bearer \(bridge.connectionToken)",
        "Connection: close",
        "",
        "",
      ].joined(separator: "\r\n").utf8
    )

    reader.start(request: request)
    await fulfillment(of: [responseExpectation], timeout: 3)

    XCTAssertNil(reader.errorDescription)
    let response = try XCTUnwrap(String(data: reader.response, encoding: .utf8))
    XCTAssertTrue(response.hasPrefix("HTTP/1.1 404 Not Found\r\n"), response)
  }

  func testLegacyIndependentExpiryForcesRotationBeforeTokenReuse() throws {
    let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "knowledge-browser-legacy-expiry-\(UUID().uuidString)",
      isDirectory: true
    )
    let suiteName = "KnowledgeBrowserBridgeActivationTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    defer {
      defaults.removePersistentDomain(forName: suiteName)
      try? FileManager.default.removeItem(at: rootURL)
    }

    let currentDate = Date(timeIntervalSince1970: 1_700_000_000)
    defaults.set(
      currentDate.addingTimeInterval(60 * 60),
      forKey: "KnowledgeBrowserBridge.connectionTokenExpiresAt.v1"
    )
    let keychain = KeychainTokenStore(
      service: KeychainCredentialServices.browserBridge,
      accountPrefix: "browser-legacy-expiry-test-\(UUID().uuidString)",
      inMemory: true,
      allowsAuthenticationInteraction: false
    )
    let tokenStore = KnowledgeBrowserConnectionTokenStore(keychain: keychain)
    let legacyToken = String(repeating: "a", count: 64)
    try tokenStore.persist(legacyToken)

    let bridge = KnowledgeBrowserBridge(
      knowledge: KnowledgeStore(
        service: KnowledgeLibraryService(
          rootURL: rootURL.appendingPathComponent("KnowledgeLibrary", isDirectory: true)
        )
      ),
      defaults: defaults,
      connectionTokenKeychainStore: keychain,
      importOperationLedgerURL: rootURL.appendingPathComponent("import-ledger.plist"),
      now: { currentDate }
    )

    bridge.setEnabled(true)

    XCTAssertNotEqual(bridge.connectionToken, legacyToken)
    XCTAssertEqual(try tokenStore.token(), bridge.connectionToken)
    XCTAssertNotNil(defaults.data(forKey: "KnowledgeBrowserBridge.connectionTokenLease.v2"))
    XCTAssertNil(defaults.object(forKey: "KnowledgeBrowserBridge.connectionTokenExpiresAt.v1"))

    let rotatedToken = bridge.connectionToken
    bridge.stop()
    let restartedBridge = KnowledgeBrowserBridge(
      knowledge: KnowledgeStore(
        service: KnowledgeLibraryService(
          rootURL: rootURL.appendingPathComponent("KnowledgeLibrary", isDirectory: true)
        )
      ),
      defaults: defaults,
      connectionTokenKeychainStore: keychain,
      importOperationLedgerURL: rootURL.appendingPathComponent("import-ledger.plist"),
      now: { currentDate }
    )
    restartedBridge.setEnabled(true)

    XCTAssertEqual(restartedBridge.connectionToken, rotatedToken)
  }

  private func waitUntil(
    attempts: Int = 300,
    condition: @MainActor () -> Bool
  ) async throws -> Bool {
    for _ in 0..<attempts {
      if condition() { return true }
      try await Task.sleep(for: .milliseconds(10))
    }
    return false
  }
}

private final class BrowserBridgeTestResponseReader: @unchecked Sendable {
  private let connection: NWConnection
  private let completion: XCTestExpectation
  private let lock = NSLock()
  private var receivedData = Data()
  private var didComplete = false
  private var failureDescription: String?

  init(connection: NWConnection, completion: XCTestExpectation) {
    self.connection = connection
    self.completion = completion
  }

  var response: Data {
    lock.lock()
    defer { lock.unlock() }
    return receivedData
  }

  var errorDescription: String? {
    lock.lock()
    defer { lock.unlock() }
    return failureDescription
  }

  func start(request: Data) {
    connection.stateUpdateHandler = { [weak self] state in
      guard let self else { return }
      switch state {
      case .ready:
        connection.send(
          content: request,
          completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if let error {
              finish(error: error)
            } else {
              receive()
            }
          })
      case .failed(let error):
        finish(error: error)
      default:
        break
      }
    }
    connection.start(queue: DispatchQueue(label: "KnowledgeBrowserBridgeUnknownRouteTests.client"))
  }

  private func receive() {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1_024) {
      [weak self] data, _, isComplete, error in
      guard let self else { return }
      if let data {
        lock.lock()
        receivedData.append(data)
        lock.unlock()
      }
      if let error {
        finish(error: error)
      } else if isComplete {
        finish(error: nil)
      } else {
        receive()
      }
    }
  }

  private func finish(error: NWError?) {
    lock.lock()
    guard !didComplete else {
      lock.unlock()
      return
    }
    didComplete = true
    failureDescription = error?.localizedDescription
    lock.unlock()
    connection.cancel()
    completion.fulfill()
  }
}
