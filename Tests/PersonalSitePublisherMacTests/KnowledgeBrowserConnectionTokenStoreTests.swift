import Foundation
import XCTest
@testable import PersonalSitePublisherMac

final class KnowledgeBrowserConnectionTokenStoreTests: XCTestCase {
  func testPersistWritesOwnerOnlyFileAndRemovesLegacyDefaults() throws {
    let fixture = try makeFixture()
    defer { fixture.cleanup() }
    fixture.defaults.set("legacy-token", forKey: fixture.legacyKey)
    let fileURL = fixture.rootURL.appendingPathComponent("connection-token")
    let store = makeStore(fileURL: fileURL, fixture: fixture)

    try store.persist("new-token")

    XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), "new-token")
    XCTAssertNil(fixture.defaults.object(forKey: fixture.legacyKey))
    let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
    let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
    XCTAssertEqual(permissions.intValue & 0o777, 0o600)
  }

  func testTokenReadsLegacyDefaultsBeforeFirstFileMigration() throws {
    let fixture = try makeFixture()
    defer { fixture.cleanup() }
    fixture.defaults.set("legacy-token", forKey: fixture.legacyKey)
    let store = makeStore(
      fileURL: fixture.rootURL.appendingPathComponent("connection-token"),
      fixture: fixture
    )

    XCTAssertEqual(try store.token(), "legacy-token")
  }

  func testPersistFallsBackToDefaultsWhenFileURLIsUnavailable() throws {
    let fixture = try makeFixture()
    defer { fixture.cleanup() }
    let store = makeStore(fileURL: nil, fixture: fixture)

    try store.persist("fallback-token")

    XCTAssertEqual(try store.token(), "fallback-token")
  }

  func testInvalidTokenFileIsRejected() throws {
    let fixture = try makeFixture()
    defer { fixture.cleanup() }
    let fileURL = fixture.rootURL.appendingPathComponent("connection-token")
    try Data().write(to: fileURL)
    let store = makeStore(fileURL: fileURL, fixture: fixture)

    XCTAssertThrowsError(try store.token()) { error in
      XCTAssertEqual(
        error as? KnowledgeBrowserConnectionTokenStoreError,
        .invalidData
      )
    }
  }

  private func makeStore(
    fileURL: URL?,
    fixture: ConnectionTokenFixture
  ) -> KnowledgeBrowserConnectionTokenStore {
    KnowledgeBrowserConnectionTokenStore(
      fileURL: fileURL,
      defaults: KnowledgeBrowserConnectionTokenDefaults(fixture.defaults),
      legacyDefaultsKey: fixture.legacyKey
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
