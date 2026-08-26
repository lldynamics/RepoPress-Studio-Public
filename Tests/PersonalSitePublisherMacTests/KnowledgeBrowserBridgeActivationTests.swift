import Foundation
import PublishingWorkbenchCore
import XCTest

@testable import PersonalSitePublisherMac

@MainActor
final class KnowledgeBrowserBridgeActivationTests: XCTestCase {
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
}
