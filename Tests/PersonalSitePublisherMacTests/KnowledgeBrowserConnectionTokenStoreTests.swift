import Foundation
import PublishingWorkbenchCore
import XCTest
@testable import PersonalSitePublisherMac

final class KnowledgeBrowserConnectionTokenStoreTests: XCTestCase {
  func testPersistUsesKeychainAndLeavesLegacyCopiesUntouched() throws {
    let fixture = try makeFixture()
    defer { fixture.cleanup() }
    fixture.defaults.set("legacy-token", forKey: fixture.legacyKey)
    let legacyFileURL = fixture.rootURL.appendingPathComponent("connection-token")
    try Data("legacy-file-token".utf8).write(to: legacyFileURL)

    let store = makeStore()
    try store.persist("keychain-token")

    XCTAssertEqual(try store.token(), "keychain-token")
    XCTAssertEqual(fixture.defaults.string(forKey: fixture.legacyKey), "legacy-token")
    XCTAssertEqual(
      try String(contentsOf: legacyFileURL, encoding: .utf8),
      "legacy-file-token"
    )
  }

  func testTokenDoesNotReadLegacyFileOrDefaults() throws {
    let fixture = try makeFixture()
    defer { fixture.cleanup() }
    fixture.defaults.set("legacy-token", forKey: fixture.legacyKey)
    let legacyFileURL = fixture.rootURL.appendingPathComponent("connection-token")
    try Data("legacy-file-token".utf8).write(to: legacyFileURL)

    let store = makeStore()

    XCTAssertNil(try store.token())
  }

  func testEmptyTokenIsRejected() throws {
    let store = makeStore()

    XCTAssertThrowsError(try store.persist("")) { error in
      XCTAssertEqual(
        error as? KnowledgeBrowserConnectionTokenStoreError,
        .invalidData
      )
    }
  }

  private func makeStore() -> KnowledgeBrowserConnectionTokenStore {
    KnowledgeBrowserConnectionTokenStore(
      keychain: KeychainTokenStore(
        service: KeychainCredentialServices.browserBridge,
        accountPrefix: "browser-connection-token-test-\(UUID().uuidString)",
        inMemory: true
      )
    )
  }

  private func makeFixture() throws -> ConnectionTokenFixture {
    let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "browser-connection-token-store-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    let suiteName = "KnowledgeBrowserConnectionTokenStoreTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    return ConnectionTokenFixture(
      rootURL: rootURL,
      defaults: defaults,
      suiteName: suiteName,
      legacyKey: "legacy-token"
    )
  }
}

private struct ConnectionTokenFixture {
  let rootURL: URL
  let defaults: UserDefaults
  let suiteName: String
  let legacyKey: String

  func cleanup() {
    defaults.removePersistentDomain(forName: suiteName)
    try? FileManager.default.removeItem(at: rootURL)
  }
}
