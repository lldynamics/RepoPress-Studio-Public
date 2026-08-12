import XCTest

@testable import PublishingWorkbenchCore

final class AICredentialStoreTests: XCTestCase {
  func testLocalFileIsDefaultAndUsesOwnerOnlyPermissions() throws {
    let fixture = try makeFixture(defaultMode: .localFile)
    defer { removeFixture(at: fixture.fileURL) }
    let connectionID = UUID()

    XCTAssertEqual(fixture.store.storageMode, .localFile)
    try fixture.store.saveToken("  sk-local  ", forConnectionProfileID: connectionID)

    XCTAssertEqual(
      try fixture.store.token(forConnectionProfileID: connectionID),
      "sk-local"
    )
    XCTAssertNil(try fixture.keychain.aiToken(forConnectionProfileID: connectionID))
    XCTAssertEqual(
      try filePermissions(at: fixture.fileURL),
      0o600
    )
  }

  func testSelectingKeychainWritesOnlyToKeychain() throws {
    let fixture = try makeFixture(defaultMode: .localFile)
    defer { removeFixture(at: fixture.fileURL) }
    let connectionID = UUID()

    fixture.store.setStorageMode(.keychain)
    try fixture.store.saveToken("sk-keychain", forConnectionProfileID: connectionID)

    XCTAssertEqual(fixture.store.storageMode, .keychain)
    XCTAssertEqual(
      try fixture.keychain.aiToken(forConnectionProfileID: connectionID),
      "sk-keychain"
    )
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.fileURL.path))
  }

  func testSwitchingStorageModeDoesNotCopyOrReadAnotherSource() throws {
    let fixture = try makeFixture(defaultMode: .localFile)
    defer { removeFixture(at: fixture.fileURL) }
    let connectionID = UUID()
    try fixture.store.saveToken("sk-local", forConnectionProfileID: connectionID)

    fixture.store.setStorageMode(.keychain)

    XCTAssertNil(try fixture.store.token(forConnectionProfileID: connectionID))
    XCTAssertEqual(
      try fixture.keychain.aiToken(forConnectionProfileID: connectionID),
      nil
    )

    fixture.store.setStorageMode(.localFile)
    XCTAssertEqual(
      try fixture.store.token(forConnectionProfileID: connectionID),
      "sk-local"
    )
  }

  func testSessionCredentialIsNotWrittenToDiskOrKeychain() throws {
    let fixture = try makeFixture(defaultMode: .session)
    defer { removeFixture(at: fixture.fileURL) }
    let connectionID = UUID()

    try fixture.store.saveToken("sk-session", forConnectionProfileID: connectionID)

    XCTAssertEqual(
      try fixture.store.token(forConnectionProfileID: connectionID),
      "sk-session"
    )
    XCTAssertNil(try fixture.keychain.aiToken(forConnectionProfileID: connectionID))
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.fileURL.path))
  }

  func testEndpointInvalidationPreventsInactiveKeychainCredentialFromReactivating() throws {
    let fixture = try makeFixture(defaultMode: .keychain)
    defer { removeFixture(at: fixture.fileURL) }
    let connectionID = UUID()
    try fixture.store.saveToken("sk-old-endpoint", forConnectionProfileID: connectionID)

    fixture.store.setStorageMode(.localFile)
    try fixture.store.invalidateTokenAcrossStorageModes(
      forConnectionProfileID: connectionID
    )
    fixture.store.setStorageMode(.keychain)

    XCTAssertNil(try fixture.store.token(forConnectionProfileID: connectionID))
    XCTAssertFalse(
      try fixture.store.availability(forConnectionProfileID: connectionID).hasToken
    )

    try fixture.store.saveToken("sk-new-endpoint", forConnectionProfileID: connectionID)
    XCTAssertEqual(
      try fixture.store.token(forConnectionProfileID: connectionID),
      "sk-new-endpoint"
    )
  }

  private func makeFixture(
    defaultMode: AICredentialStorageMode
  ) throws -> (store: AICredentialStore, keychain: KeychainTokenStore, fileURL: URL) {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let fileURL = directory.appendingPathComponent("credentials.json")
    let keychain = KeychainTokenStore(
      service: "PersonalSitePublisherMac.Tests.AICredentialStore.\(UUID().uuidString)",
      accountPrefix: "ai-credential-store-tests",
      inMemory: true
    )
    return (
      AICredentialStore(
        keychainTokenStore: keychain,
        localFileURL: fileURL,
        userDefaults: nil,
        defaultMode: defaultMode
      ),
      keychain,
      fileURL
    )
  }

  private func filePermissions(at fileURL: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
    return try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue
  }

  private func removeFixture(at fileURL: URL) {
    try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
  }
}
