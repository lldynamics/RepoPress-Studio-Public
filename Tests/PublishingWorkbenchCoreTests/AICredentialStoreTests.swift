import XCTest

@testable import PublishingWorkbenchCore

final class AICredentialStoreTests: XCTestCase {
  func testNewInstallDefaultsToKeychainWithoutCreatingCredentialsFile() throws {
    let fixture = try makeFixture()
    defer { removeFixture(at: fixture.fileURL) }
    let connectionID = UUID()

    XCTAssertEqual(fixture.store.storageMode, .keychain)
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.fileURL.path))

    XCTAssertNil(try fixture.store.token(forConnectionProfileID: connectionID))
    let availability = try fixture.store.availability(
      forConnectionProfileID: connectionID
    )
    XCTAssertFalse(availability.hasToken)
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.fileURL.path))
  }

  func testInMemoryConvenienceInitializerDefaultsToKeychain() {
    let keychain = KeychainTokenStore(
      service: "PersonalSitePublisherMac.Tests.AICredentialStore.\(UUID().uuidString)",
      accountPrefix: "ai-credential-store-tests",
      inMemory: true
    )

    let store = AICredentialStore(keychainTokenStore: keychain)

    XCTAssertEqual(store.storageMode, .keychain)
  }

  func testExplicitLocalFileUsesOwnerOnlyPermissionsAndBackupExclusion() throws {
    let backupExclusionRecorder = BackupExclusionRecorder()
    let fixture = try makeFixture(
      defaultMode: .localFile,
      backupExclusionHandler: backupExclusionRecorder.record
    )
    defer { removeFixture(at: fixture.fileURL) }
    let connectionID = UUID()
    let directoryURL = fixture.fileURL.deletingLastPathComponent()

    XCTAssertEqual(fixture.store.storageMode, .localFile)
    try fixture.store.saveToken("  sk-local  ", forConnectionProfileID: connectionID)

    XCTAssertEqual(
      try fixture.store.token(forConnectionProfileID: connectionID),
      "sk-local"
    )
    XCTAssertNil(try fixture.keychain.aiToken(forConnectionProfileID: connectionID))
    XCTAssertEqual(try filePermissions(at: fixture.fileURL), 0o600)
    XCTAssertEqual(try filePermissions(at: directoryURL), 0o700)
    XCTAssertTrue(backupExclusionRecorder.contains(directoryURL))
    XCTAssertTrue(backupExclusionRecorder.contains(fixture.fileURL))
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
    XCTAssertNil(try fixture.keychain.aiToken(forConnectionProfileID: connectionID))

    try fixture.store.saveToken("sk-keychain", forConnectionProfileID: connectionID)
    fixture.store.setStorageMode(.session)
    XCTAssertNil(try fixture.store.token(forConnectionProfileID: connectionID))

    try fixture.store.saveToken("sk-session", forConnectionProfileID: connectionID)
    fixture.store.setStorageMode(.keychain)
    XCTAssertEqual(
      try fixture.store.token(forConnectionProfileID: connectionID),
      "sk-keychain"
    )
    fixture.store.setStorageMode(.session)
    XCTAssertEqual(
      try fixture.store.token(forConnectionProfileID: connectionID),
      "sk-session"
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

  func testExplicitLocalFilePreferenceRestoresExistingLocalCredential() throws {
    let suiteName = "AICredentialStoreTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let fixture = try makeFixture(userDefaults: defaults)
    defer { removeFixture(at: fixture.fileURL) }
    let connectionID = UUID()
    fixture.store.setStorageMode(.localFile)
    try fixture.store.saveToken("sk-existing-local", forConnectionProfileID: connectionID)

    let restored = try makeFixture(
      userDefaults: defaults,
      fileURL: fixture.fileURL
    )
    XCTAssertEqual(restored.store.storageMode, .localFile)
    XCTAssertEqual(
      try restored.store.token(forConnectionProfileID: connectionID),
      "sk-existing-local"
    )
  }

  func testLegacyLocalFileIsIgnoredUntilExplicitLocalFileSelection() throws {
    let writer = try makeFixture(defaultMode: .localFile)
    defer { removeFixture(at: writer.fileURL) }
    let connectionID = UUID()
    let directoryURL = writer.fileURL.deletingLastPathComponent()
    try writer.store.saveToken("sk-legacy-local", forConnectionProfileID: connectionID)
    let originalData = try Data(contentsOf: writer.fileURL)

    try FileManager.default.setAttributes(
      [.posixPermissions: NSNumber(value: 0o755)],
      ofItemAtPath: directoryURL.path
    )
    try FileManager.default.setAttributes(
      [.posixPermissions: NSNumber(value: 0o644)],
      ofItemAtPath: writer.fileURL.path
    )
    try setExcludedFromBackup(false, at: directoryURL)
    try setExcludedFromBackup(false, at: writer.fileURL)

    let backupExclusionRecorder = BackupExclusionRecorder()
    let reader = try makeFixture(
      fileURL: writer.fileURL,
      backupExclusionHandler: backupExclusionRecorder.record
    )
    XCTAssertEqual(reader.store.storageMode, .keychain)
    XCTAssertNil(try reader.store.token(forConnectionProfileID: connectionID))
    XCTAssertEqual(try Data(contentsOf: writer.fileURL), originalData)

    reader.store.setStorageMode(.localFile)
    XCTAssertEqual(
      try reader.store.token(forConnectionProfileID: connectionID),
      "sk-legacy-local"
    )
    XCTAssertEqual(try filePermissions(at: directoryURL), 0o700)
    XCTAssertEqual(try filePermissions(at: writer.fileURL), 0o600)
    XCTAssertTrue(backupExclusionRecorder.contains(directoryURL))
    XCTAssertTrue(backupExclusionRecorder.contains(writer.fileURL))
    XCTAssertEqual(try Data(contentsOf: writer.fileURL), originalData)
  }

  func testEndpointInvalidationPreventsInactiveCredentialsFromReactivating() throws {
    let fixture = try makeFixture(defaultMode: .localFile)
    defer { removeFixture(at: fixture.fileURL) }
    let connectionID = UUID()
    let legacyProfile = SiteProfile(
      name: "Legacy AI",
      aiProviderConfig: AIProviderConfig(
        preset: .custom,
        baseURL: "https://old-endpoint.example/v1",
        model: "old-model",
        requiresAPIKey: true
      )
    )

    try fixture.store.saveToken("sk-old-local", forConnectionProfileID: connectionID)
    fixture.store.setStorageMode(.session)
    try fixture.store.saveToken("sk-old-session", forConnectionProfileID: connectionID)
    fixture.store.setStorageMode(.keychain)
    try fixture.store.saveToken("sk-old-keychain", forConnectionProfileID: connectionID)
    try fixture.keychain.saveAIToken("sk-old-legacy", for: legacyProfile)
    fixture.store.setStorageMode(.localFile)

    try fixture.store.invalidateTokenAcrossStorageModes(
      forConnectionProfileID: connectionID,
      legacyProfiles: [legacyProfile]
    )

    for mode in AICredentialStorageMode.allCases {
      fixture.store.setStorageMode(mode)
      XCTAssertNil(try fixture.store.token(forConnectionProfileID: connectionID))
      let availability = try fixture.store.availability(
        forConnectionProfileID: connectionID
      )
      XCTAssertFalse(availability.hasToken)
    }

    fixture.store.setStorageMode(.keychain)
    XCTAssertNil(
      try fixture.store.token(
        forConnectionProfileID: connectionID,
        legacyProfile: legacyProfile
      )
    )
    XCTAssertFalse(
      try fixture.store.availability(
        forConnectionProfileID: connectionID,
        legacyProfile: legacyProfile
      ).hasToken
    )
    XCTAssertEqual(
      try fixture.keychain.aiToken(for: legacyProfile),
      "sk-old-legacy"
    )

    try fixture.store.saveToken("sk-new-endpoint", forConnectionProfileID: connectionID)
    XCTAssertEqual(
      try fixture.store.token(forConnectionProfileID: connectionID),
      "sk-new-endpoint"
    )
  }

  func testCredentialIsBoundToConnectionProfileIdentity() throws {
    let fixture = try makeFixture(defaultMode: .keychain)
    defer { removeFixture(at: fixture.fileURL) }
    let originalID = UUID()
    let replacementID = UUID()
    try fixture.store.saveToken("sk-original-identity", forConnectionProfileID: originalID)

    XCTAssertNil(try fixture.store.token(forConnectionProfileID: replacementID))
    XCTAssertFalse(
      try fixture.store.availability(forConnectionProfileID: replacementID).hasToken
    )
    XCTAssertNil(try fixture.keychain.aiToken(forConnectionProfileID: replacementID))
  }

  func testLocalFileReadErrorDoesNotLeakCredentialValue() throws {
    let fixture = try makeFixture(defaultMode: .localFile)
    defer { removeFixture(at: fixture.fileURL) }
    let secret = "sk-error-secret"
    let connectionID = UUID()
    let malformedJSON = """
      {"version":1,"credentials":{"\(connectionID.uuidString)":{"token":"\(secret)","updatedAt":{}}}}
      """
    try FileManager.default.createDirectory(
      at: fixture.fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data(malformedJSON.utf8).write(to: fixture.fileURL)

    do {
      _ = try fixture.store.token(forConnectionProfileID: connectionID)
      XCTFail("Expected malformed local credential file to fail")
    } catch {
      XCTAssertFalse(error.localizedDescription.contains(secret))
      XCTAssertFalse(String(describing: error).contains(secret))
    }
  }

  private func makeFixture(
    defaultMode: AICredentialStorageMode? = nil,
    userDefaults: UserDefaults? = nil,
    fileURL: URL? = nil,
    backupExclusionHandler: ((URL) throws -> Void)? = nil
  ) throws -> (store: AICredentialStore, keychain: KeychainTokenStore, fileURL: URL) {
    let resolvedFileURL =
      fileURL
      ?? FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
      .appendingPathComponent("credentials.json")
    let keychain = KeychainTokenStore(
      service: "PersonalSitePublisherMac.Tests.AICredentialStore.\(UUID().uuidString)",
      accountPrefix: "ai-credential-store-tests",
      inMemory: true
    )
    let store: AICredentialStore
    if let backupExclusionHandler {
      store = AICredentialStore(
        keychainTokenStore: keychain,
        localFileURL: resolvedFileURL,
        userDefaults: userDefaults,
        defaultMode: defaultMode ?? .keychain,
        fileManager: .default,
        backupExclusionHandler: backupExclusionHandler
      )
    } else if let defaultMode = defaultMode {
      store = AICredentialStore(
        keychainTokenStore: keychain,
        localFileURL: resolvedFileURL,
        userDefaults: userDefaults,
        defaultMode: defaultMode
      )
    } else {
      store = AICredentialStore(
        keychainTokenStore: keychain,
        localFileURL: resolvedFileURL,
        userDefaults: userDefaults
      )
    }
    return (store, keychain, resolvedFileURL)
  }

  private func filePermissions(at fileURL: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
    return try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue
  }

  private func setExcludedFromBackup(_ excluded: Bool, at url: URL) throws {
    var resourceValues = URLResourceValues()
    resourceValues.isExcludedFromBackup = excluded
    var mutableURL = url
    try mutableURL.setResourceValues(resourceValues)
  }

  private func removeFixture(at fileURL: URL) {
    try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
  }
}

private final class BackupExclusionRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var paths: Set<String> = []

  func record(_ url: URL) throws {
    lock.lock()
    defer { lock.unlock() }
    paths.insert(url.standardizedFileURL.path)
  }

  func contains(_ url: URL) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return paths.contains(url.standardizedFileURL.path)
  }
}
