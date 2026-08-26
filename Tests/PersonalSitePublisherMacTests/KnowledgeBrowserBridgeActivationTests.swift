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
      importOperationLedgerURL: rootURL.appendingPathComponent("import-ledger.plist"),
      makeListener: { _ in
        try NWListener(using: .tcp, on: .any)
      }
    )

    bridge.start()

    XCTAssertFalse(bridge.isEnabled)
    XCTAssertFalse(bridge.hasAllocatedNetworkResources)
    XCTAssertEqual(bridge.activeNetworkConnectionCount, 0)

    bridge.setEnabled(true)
    try await waitUntil {
      bridge.state == .ready && bridge.activeListenerPort != nil
    }
    XCTAssertTrue(bridge.hasAllocatedNetworkResources)

    let activePort = try XCTUnwrap(bridge.activeListenerPort)
    let port = try XCTUnwrap(NWEndpoint.Port(rawValue: activePort))
    let client = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
    client.start(queue: DispatchQueue(label: "KnowledgeBrowserBridgeActivationTests.client"))
    defer { client.cancel() }
    try await waitUntil {
      bridge.activeNetworkConnectionCount == 1
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
  ) async throws {
    for _ in 0..<attempts {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("Timed out waiting for browser bridge lifecycle state")
  }
}
