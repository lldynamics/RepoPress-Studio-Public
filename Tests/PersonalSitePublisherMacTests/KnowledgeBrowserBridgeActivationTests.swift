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
}
