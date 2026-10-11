import Foundation
import Security
import XCTest

@testable import PublishingAICore

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

    fixture.store.setStorageMode(.keychain, forConnectionProfileID: connectionID)
    try fixture.store.saveToken("sk-keychain", forConnectionProfileID: connectionID)

    XCTAssertEqual(fixture.store.storageMode(forConnectionProfileID: connectionID), .keychain)
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

    fixture.store.setStorageMode(.keychain, forConnectionProfileID: connectionID)
    XCTAssertNil(try fixture.store.token(forConnectionProfileID: connectionID))
    XCTAssertNil(try fixture.keychain.aiToken(forConnectionProfileID: connectionID))

    try fixture.store.saveToken("sk-keychain", forConnectionProfileID: connectionID)
    fixture.store.setStorageMode(.session, forConnectionProfileID: connectionID)
    XCTAssertNil(try fixture.store.token(forConnectionProfileID: connectionID))

    try fixture.store.saveToken("sk-session", forConnectionProfileID: connectionID)
    fixture.store.setStorageMode(.keychain, forConnectionProfileID: connectionID)
    XCTAssertEqual(
      try fixture.store.token(forConnectionProfileID: connectionID),
      "sk-keychain"
    )
    fixture.store.setStorageMode(.session, forConnectionProfileID: connectionID)
    XCTAssertEqual(
      try fixture.store.token(forConnectionProfileID: connectionID),
      "sk-session"
    )
    fixture.store.setStorageMode(.localFile, forConnectionProfileID: connectionID)
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

    reader.store.setStorageMode(.localFile, forConnectionProfileID: connectionID)
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
    fixture.store.setStorageMode(.session, forConnectionProfileID: connectionID)
    try fixture.store.saveToken("sk-old-session", forConnectionProfileID: connectionID)
    fixture.store.setStorageMode(.keychain, forConnectionProfileID: connectionID)
    try fixture.store.saveToken("sk-old-keychain", forConnectionProfileID: connectionID)
    try fixture.keychain.saveAIToken("sk-old-legacy", for: legacyProfile)
    fixture.store.setStorageMode(.localFile, forConnectionProfileID: connectionID)

    try fixture.store.invalidateTokenAcrossStorageModes(
      forConnectionProfileID: connectionID,
      legacyProfiles: [legacyProfile]
    )

    for mode in AICredentialStorageMode.allCases {
      fixture.store.setStorageMode(mode, forConnectionProfileID: connectionID)
      XCTAssertNil(try fixture.store.token(forConnectionProfileID: connectionID))
      let availability = try fixture.store.availability(
        forConnectionProfileID: connectionID
      )
      XCTAssertFalse(availability.hasToken)
    }

    fixture.store.setStorageMode(.keychain, forConnectionProfileID: connectionID)
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

  func testConnectionModesKeepAllCredentialSourcesIndependent() throws {
    let fixture = try makeFixture()
    defer { removeFixture(at: fixture.fileURL) }
    let localID = UUID()
    let keychainID = UUID()
    let sessionID = UUID()
    fixture.store.setStorageMode(.localFile, forConnectionProfileID: localID)
    fixture.store.setStorageMode(.keychain, forConnectionProfileID: keychainID)
    fixture.store.setStorageMode(.session, forConnectionProfileID: sessionID)

    try fixture.store.saveToken("local-only", forConnectionProfileID: localID)
    try fixture.store.saveToken("keychain-only", forConnectionProfileID: keychainID)
    try fixture.store.saveToken("session-only", forConnectionProfileID: sessionID)
    let localData = try Data(contentsOf: fixture.fileURL)

    fixture.store.setStorageMode(.session, forConnectionProfileID: keychainID)
    XCTAssertNil(try fixture.store.token(forConnectionProfileID: keychainID))
    XCTAssertFalse(try fixture.store.availability(forConnectionProfileID: keychainID).hasToken)
    XCTAssertEqual(try fixture.store.token(forConnectionProfileID: localID), "local-only")
    XCTAssertEqual(try fixture.store.token(forConnectionProfileID: sessionID), "session-only")
    XCTAssertEqual(
      try fixture.keychain.aiToken(forConnectionProfileID: keychainID), "keychain-only")
    XCTAssertNil(try fixture.keychain.aiToken(forConnectionProfileID: localID))
    XCTAssertNil(try fixture.keychain.aiToken(forConnectionProfileID: sessionID))
    XCTAssertEqual(try Data(contentsOf: fixture.fileURL), localData)

    try fixture.store.saveToken("second-session-only", forConnectionProfileID: keychainID)
    try fixture.store.deleteToken(forConnectionProfileID: keychainID)
    fixture.store.setStorageMode(.keychain, forConnectionProfileID: keychainID)
    XCTAssertEqual(try fixture.store.token(forConnectionProfileID: keychainID), "keychain-only")
    XCTAssertEqual(try fixture.store.token(forConnectionProfileID: localID), "local-only")
  }

  func testPreferenceMigrationDoesNotReadMalformedLocalSecretsAndFreezesExistingModes() throws {
    let suiteName = "AICredentialStoreTests.Migration.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let fixture = try makeFixture(userDefaults: defaults)
    defer { removeFixture(at: fixture.fileURL) }
    try FileManager.default.createDirectory(
      at: fixture.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    let malformedData = Data("unreadable credential document".utf8)
    try malformedData.write(to: fixture.fileURL)
    let existingIDs = [UUID(), UUID()]

    defaults.set("localFile", forKey: AICredentialStore.storageModePreferenceKey)
    fixture.store.initializeStorageModes(forConnectionProfileIDs: existingIDs)
    fixture.store.setStorageMode(.session)

    for id in existingIDs {
      XCTAssertEqual(fixture.store.storageMode(forConnectionProfileID: id), .localFile)
    }
    XCTAssertEqual(fixture.store.storageMode(forConnectionProfileID: UUID()), .session)
    XCTAssertEqual(try Data(contentsOf: fixture.fileURL), malformedData)
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

@MainActor
final class AIConnectionCredentialStorageModeTests: XCTestCase {
  func testLegacyPreferencesFreezeBoundAndUnusedConnectionsAndRestoreAfterRestart() throws {
    for mode in AICredentialStorageMode.allCases {
      let fixture = try makeFixture(legacyMode: mode)
      defer { fixture.remove() }
      let originalIDs = fixture.store.aiConnectionProfiles.map(\.id)
      for id in originalIDs {
        XCTAssertEqual(fixture.store.ai.credentialStorageMode(forConnectionProfileID: id), mode)
      }
      fixture.credentials.setStorageMode(.session)
      for id in originalIDs {
        XCTAssertEqual(fixture.credentials.storageMode(forConnectionProfileID: id), mode)
      }
      let created = fixture.store.createAIConnectionProfile(named: "New default", preset: .custom)
      XCTAssertEqual(
        fixture.store.ai.credentialStorageMode(forConnectionProfileID: created.id), .session)

      let restoredCredentials = fixture.reopenedCredentials()
      let restored = fixture.reopenedStore(credentials: restoredCredentials)
      for id in originalIDs {
        XCTAssertEqual(restored.ai.credentialStorageMode(forConnectionProfileID: id), mode)
      }
      XCTAssertEqual(
        restored.ai.credentialStorageMode(forConnectionProfileID: created.id), .session)
    }
  }

  func testScopedSaveReadAvailabilityAndRestartUseEachConnectionsSource() throws {
    let fixture = try makeFixture()
    defer { fixture.remove() }
    let a = fixture.store.activeAIConnectionProfile
    let b = try XCTUnwrap(fixture.store.aiConnectionProfiles.first { $0.id != a.id })
    fixture.store.aiStore.grantAIDataSharingConsent(for: a.config, enablingRemoteAI: true)
    fixture.store.aiStore.grantAIDataSharingConsent(for: b.config, enablingRemoteAI: true)
    fixture.store.ai.setCredentialStorageMode(.localFile, connectionProfileID: a.id)
    fixture.store.ai.setCredentialStorageMode(.keychain, connectionProfileID: b.id)
    XCTAssertTrue(fixture.store.ai.saveAPIKey("local-A", connectionProfileID: a.id))
    XCTAssertTrue(fixture.store.ai.saveAPIKey("keychain-B", connectionProfileID: b.id))
    XCTAssertTrue(fixture.store.ai.tokenAvailability.hasToken)
    XCTAssertTrue(fixture.store.ai.keyAvailability(forConnectionProfileID: b.id).hasToken)
    XCTAssertEqual(try fixture.store.aiStore.settingsAPIKey(for: a), "local-A")
    XCTAssertEqual(try fixture.store.aiStore.settingsAPIKey(for: b), "keychain-B")
    XCTAssertNil(try fixture.keychain.aiToken(forConnectionProfileID: a.id))
    XCTAssertEqual(try fixture.keychain.aiToken(forConnectionProfileID: b.id), "keychain-B")

    let restored = fixture.reopenedStore(credentials: fixture.reopenedCredentials())
    XCTAssertEqual(restored.ai.credentialStorageMode(forConnectionProfileID: a.id), .localFile)
    XCTAssertEqual(restored.ai.credentialStorageMode(forConnectionProfileID: b.id), .keychain)
    XCTAssertEqual(try restored.aiStore.settingsAPIKey(for: a), "local-A")
    XCTAssertEqual(try restored.aiStore.settingsAPIKey(for: b), "keychain-B")
    let snapshotData = try JSONEncoder().encode(fixture.snapshot)
    let snapshotText = try XCTUnwrap(String(data: snapshotData, encoding: .utf8))
    XCTAssertFalse(snapshotText.contains("local-A"))
    XCTAssertFalse(snapshotText.contains("keychain-B"))
  }

  func testChangingInactiveConnectionModeCancelsOnlyItsKeyDependentRequests() throws {
    let fixture = try makeFixture()
    defer { fixture.remove() }
    let a = fixture.store.activeAIConnectionProfile
    let b = try XCTUnwrap(fixture.store.aiConnectionProfiles.first { $0.id != a.id })
    let ai = fixture.store.aiStore
    let aLane = AIGenerationLane.action
    let bLane = AIGenerationLane.metadata(UUID())
    let aGeneration = ai.beginAIRequest(aLane)
    _ = ai.bindNonStreamingAuthorization(aLane, profile: fixture.store.activeProfile)
    let bGeneration = ai.beginAIRequest(bLane)
    var bProfile = fixture.store.activeProfile
    bProfile.aiConnectionProfileID = b.id
    _ = ai.bindNonStreamingAuthorization(bLane, profile: bProfile)
    let noKeyGeneration = ai.beginAIRequest(.writingStyle)
    var noKeyConfig = b.config
    noKeyConfig.requiresAPIKey = false
    ai.aiRequests[.writingStyle]?.authorization = AINonStreamingAuthorizationBinding(
      profileID: bProfile.id, connectionID: b.id, config: noKeyConfig
    )
    let producer = Task {
      do { try await Task.sleep(for: .seconds(60)) } catch {}
    }
    defer { producer.cancel() }
    ai.bindAIChatAuthorization(operationID: UUID(), config: a.config, connectionID: a.id)
      .register(producer)

    fixture.store.ai.setCredentialStorageMode(.session, connectionProfileID: b.id)

    XCTAssertEqual(ai.currentAIRequestGeneration(aLane), aGeneration)
    XCTAssertNil(ai.currentAIRequestGeneration(bLane))
    XCTAssertEqual(ai.currentAIRequestGeneration(.writingStyle), noKeyGeneration)
    XCTAssertFalse(producer.isCancelled)
    XCTAssertNoThrow(try ai.checkAIRequest(aLane, generation: aGeneration))
    XCTAssertThrowsError(try ai.checkAIRequest(bLane, generation: bGeneration))
    XCTAssertEqual(fixture.store.ai.credentialStorageMode, .keychain)
    fixture.store.ai.setCredentialStorageMode(.localFile)
    XCTAssertEqual(fixture.store.ai.credentialStorageMode, .localFile)
    XCTAssertEqual(fixture.store.ai.credentialStorageMode(forConnectionProfileID: b.id), .session)
    XCTAssertNil(ai.currentAIRequestGeneration(aLane))
    XCTAssertTrue(producer.isCancelled)
  }

  func testInactiveConnectionEndpointChangeInvalidatesAllItsModesWithoutAffectingActiveKey() throws
  {
    let fixture = try makeFixture()
    defer { fixture.remove() }
    let a = fixture.store.activeAIConnectionProfile
    var b = try XCTUnwrap(fixture.store.aiConnectionProfiles.first { $0.id != a.id })
    XCTAssertTrue(fixture.store.ai.saveAPIKey("active-A", connectionProfileID: a.id))
    for mode in AICredentialStorageMode.allCases {
      fixture.store.ai.setCredentialStorageMode(mode, connectionProfileID: b.id)
      XCTAssertTrue(
        fixture.store.ai.saveAPIKey("old-B-\(mode.rawValue)", connectionProfileID: b.id))
    }
    fixture.store.ai.setCredentialStorageMode(.localFile, connectionProfileID: b.id)
    b.config.baseURL = "https://new-b.example/v1"
    XCTAssertTrue(fixture.store.updateAIConnectionProfile(b))
    for mode in AICredentialStorageMode.allCases {
      fixture.store.ai.setCredentialStorageMode(mode, connectionProfileID: b.id)
      XCTAssertNil(try fixture.credentials.token(forConnectionProfileID: b.id))
      XCTAssertFalse(fixture.store.ai.keyAvailability(forConnectionProfileID: b.id).hasToken)
    }
    XCTAssertEqual(try fixture.credentials.token(forConnectionProfileID: a.id), "active-A")
    XCTAssertTrue(fixture.store.ai.tokenAvailability.hasToken)
    XCTAssertTrue(fixture.store.ai.saveAPIKey("new-B", connectionProfileID: b.id))
    XCTAssertEqual(try fixture.credentials.token(forConnectionProfileID: b.id), "new-B")
  }

  func testCopiesInheritModeWithoutCopyingCredentialsAndSessionSecretsDoNotRestart() throws {
    let fixture = try makeFixture()
    defer { fixture.remove() }
    let original = fixture.store.activeAIConnectionProfile
    fixture.store.ai.setCredentialStorageMode(.session, connectionProfileID: original.id)
    XCTAssertTrue(fixture.store.ai.saveAPIKey("session-original"))
    let copy = try XCTUnwrap(fixture.store.duplicateAIConnectionProfile(original.id))
    let siteCopy = try XCTUnwrap(
      fixture.store.duplicateAIConnectionProfileForActiveSite(original.id))
    for id in [copy.id, siteCopy.id] {
      XCTAssertEqual(fixture.store.ai.credentialStorageMode(forConnectionProfileID: id), .session)
      XCTAssertFalse(fixture.store.ai.keyAvailability(forConnectionProfileID: id).hasToken)
      XCTAssertNil(try fixture.credentials.token(forConnectionProfileID: id))
    }
    XCTAssertEqual(
      try fixture.credentials.token(forConnectionProfileID: original.id), "session-original")
    let reopened = fixture.reopenedCredentials()
    XCTAssertEqual(reopened.storageMode(forConnectionProfileID: original.id), .session)
    XCTAssertNil(try reopened.token(forConnectionProfileID: original.id))
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.credentialFileURL.path))
  }

  func testLegacyCleanupUsesPreviousConnectionsModeInsteadOfDefaultOrReplacement() throws {
    for previousMode in [AICredentialStorageMode.keychain, .localFile] {
      let fixture = try makeFixture()
      defer { fixture.remove() }
      let originalID = fixture.store.activeAIConnectionProfile.id
      let replacement = try XCTUnwrap(
        fixture.store.aiConnectionProfiles.first { $0.id != originalID })
      fixture.store.ai.setCredentialStorageMode(previousMode, connectionProfileID: originalID)
      fixture.credentials.setStorageMode(previousMode == .keychain ? .session : .keychain)
      fixture.store.ai.setCredentialStorageMode(.session, connectionProfileID: replacement.id)
      var legacy = fixture.store.activeProfile
      legacy.aiConnectionProfileID = nil
      try fixture.keychain.saveAIToken("legacy-original", for: legacy)

      XCTAssertTrue(fixture.store.selectAIConnectionProfile(replacement.id))

      XCTAssertEqual(
        try fixture.keychain.aiToken(for: legacy),
        previousMode == .keychain ? nil : "legacy-original"
      )
    }
  }

  func testFailedScopedSaveAndDeleteKeepMetadataAndNeverReportSuccess() throws {
    let fixture = try makeFixture()
    defer { fixture.remove() }
    let a = fixture.store.activeAIConnectionProfile
    let b = try XCTUnwrap(fixture.store.aiConnectionProfiles.first { $0.id != a.id })
    XCTAssertTrue(fixture.store.ai.saveAPIKey("surviving-A", connectionProfileID: a.id))
    fixture.store.ai.setCredentialStorageMode(.localFile, connectionProfileID: b.id)
    try FileManager.default.createDirectory(
      at: fixture.credentialFileURL, withIntermediateDirectories: true
    )

    XCTAssertFalse(fixture.store.ai.saveAPIKey("cannot-save", connectionProfileID: b.id))
    XCTAssertTrue(fixture.store.ai.actionMessage?.contains("保存失败") == true)
    fixture.store.ai.deleteAPIKey(connectionProfileID: b.id)
    XCTAssertTrue(fixture.store.ai.actionMessage?.contains("删除失败") == true)
    XCTAssertFalse(fixture.store.deleteAIConnectionProfile(b.id))
    XCTAssertNotNil(fixture.store.aiConnectionProfile(for: b.id))
    XCTAssertEqual(fixture.credentials.storageMode(forConnectionProfileID: b.id), .localFile)
    XCTAssertNotNil(
      fixture.store.ai.keyAvailability(forConnectionProfileID: b.id).accessFailureMessage)
    XCTAssertEqual(try fixture.credentials.token(forConnectionProfileID: a.id), "surviving-A")
    XCTAssertTrue(fixture.store.ai.tokenAvailability.hasToken)
  }

  func testDeletingUnusedConnectionRemovesOnlyItsSelectedSourceAndModePreference() throws {
    let fixture = try makeFixture()
    defer { fixture.remove() }
    let activeID = fixture.store.activeAIConnectionProfile.id
    let unused = try XCTUnwrap(fixture.store.aiConnectionProfiles.first { $0.id != activeID })
    fixture.store.ai.setCredentialStorageMode(.localFile, connectionProfileID: unused.id)
    XCTAssertTrue(fixture.store.ai.saveAPIKey("selected-local", connectionProfileID: unused.id))
    try fixture.keychain.saveAIToken("inactive-keychain", forConnectionProfileID: unused.id)

    XCTAssertTrue(fixture.store.deleteAIConnectionProfile(unused.id))

    XCTAssertNil(fixture.store.aiConnectionProfile(for: unused.id))
    XCTAssertEqual(
      try fixture.keychain.aiToken(forConnectionProfileID: unused.id), "inactive-keychain")
    let modes = fixture.defaults.dictionary(
      forKey: AICredentialStore.storageModePreferenceKey + ".connections"
    )
    XCTAssertNil(modes?[unused.id.uuidString.lowercased()])
    fixture.credentials.setStorageMode(.localFile, forConnectionProfileID: unused.id)
    XCTAssertNil(try fixture.credentials.token(forConnectionProfileID: unused.id))
  }

  func testConnectionTestCancellationIsBoundToItsRequestedConnection() async throws {
    for changesTestedConnection in [false, true] {
      let barrier = StorageModeDiscoveryBarrier()
      let service = AIConnectionTestService(
        client: AIChatCompletionClient(
          transport: StorageModeConnectionTestTransport(barrier: barrier))
      )
      let fixture = try makeFixture(connectionTestService: service)
      defer { fixture.remove() }
      let a = fixture.store.activeAIConnectionProfile
      let b = try XCTUnwrap(fixture.store.aiConnectionProfiles.first { $0.id != a.id })
      XCTAssertTrue(fixture.store.ai.saveAPIKey("test-B", connectionProfileID: b.id))
      fixture.store.aiStore.grantAIDataSharingConsent(for: b.config, enablingRemoteAI: true)
      let request = Task { await fixture.store.ai.testConnection(connectionProfileID: b.id) }
      await barrier.waitUntilEntered()

      fixture.store.ai.setCredentialStorageMode(
        .session, connectionProfileID: changesTestedConnection ? b.id : a.id
      )
      let modeChangeMessage = fixture.store.ai.actionMessage
      await barrier.release()
      let report = await request.value

      if changesTestedConnection {
        XCTAssertNil(report)
        XCTAssertEqual(fixture.store.ai.actionMessage, modeChangeMessage)
      } else {
        XCTAssertNotNil(report)
      }
    }
  }

  func testModelDiscoveryCancelsForCredentialRotationAndConsentRevocation() async throws {
    for rotatesCredential in [false, true] {
      let fixture = try makeFixture()
      defer { fixture.remove() }
      let connection = fixture.store.activeAIConnectionProfile
      XCTAssertTrue(fixture.store.ai.saveAPIKey("original-key"))
      fixture.store.aiStore.grantAIDataSharingConsent(
        for: connection.config, enablingRemoteAI: true)
      let barrier = StorageModeDiscoveryBarrier()
      let service = AIModelDiscoveryService(
        transport: StorageModeDiscoveryTransport(barrier: barrier), cache: AIModelDiscoveryCache()
      )
      let request = Task {
        try await fixture.store.aiStore.discoverAIModels(
          forConnectionProfileID: connection.id, requestedConfig: connection.config,
          service: service
        )
      }
      await barrier.waitUntilEntered()
      if rotatesCredential {
        XCTAssertTrue(fixture.store.ai.saveAPIKey("rotated-key"))
      } else {
        fixture.store.aiStore.revokeAIDataSharingConsent(connectionProfileID: connection.id)
      }
      XCTAssertNil(fixture.store.aiStore.currentAIRequestGeneration(.modelDiscovery(connection.id)))
      await barrier.release()
      do {
        _ = try await request.value
        XCTFail("An obsolete authorization must not return discovered models")
      } catch is CancellationError {
      } catch {
        XCTFail("Unexpected error: \(error)")
      }
    }
  }

  func testModelDiscoverySurvivesOtherModeChangeAndRejectsLateResultAfterOwnModeChange()
    async throws
  {
    let fixture = try makeFixture()
    defer { fixture.remove() }
    let a = fixture.store.activeAIConnectionProfile
    let b = try XCTUnwrap(fixture.store.aiConnectionProfiles.first { $0.id != a.id })
    for connection in [a, b] {
      XCTAssertTrue(
        fixture.store.ai.saveAPIKey("discovery-key", connectionProfileID: connection.id))
      fixture.store.aiStore.grantAIDataSharingConsent(
        for: connection.config, enablingRemoteAI: true)
    }
    let barrier = StorageModeDiscoveryBarrier()
    let service = AIModelDiscoveryService(
      transport: StorageModeDiscoveryTransport(barrier: barrier), cache: AIModelDiscoveryCache()
    )
    let request = Task {
      try await fixture.store.aiStore.discoverAIModels(
        forConnectionProfileID: a.id, requestedConfig: a.config, service: service
      )
    }
    await barrier.waitUntilEntered()
    fixture.store.ai.setCredentialStorageMode(.session, connectionProfileID: b.id)
    XCTAssertNotNil(fixture.store.aiStore.currentAIRequestGeneration(.modelDiscovery(a.id)))
    await barrier.release()
    let models = try await request.value
    XCTAssertEqual(models.map(\.id), ["test-model"])

    let ownBarrier = StorageModeDiscoveryBarrier()
    let ownService = AIModelDiscoveryService(
      transport: StorageModeDiscoveryTransport(barrier: ownBarrier), cache: AIModelDiscoveryCache()
    )
    let ownRequest = Task {
      try await fixture.store.aiStore.discoverAIModels(
        forConnectionProfileID: a.id, requestedConfig: a.config, service: ownService
      )
    }
    await ownBarrier.waitUntilEntered()
    fixture.store.ai.setCredentialStorageMode(.localFile, connectionProfileID: a.id)
    XCTAssertNil(fixture.store.aiStore.currentAIRequestGeneration(.modelDiscovery(a.id)))
    await ownBarrier.release()
    do {
      _ = try await ownRequest.value
      XCTFail("A cancelled model request must not publish its late result")
    } catch is CancellationError {
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  func testArticleActionStillPresentsAfterOtherConnectionsDiscoverySucceedsFailsOrCancels()
    async throws
  {
    for outcome in ["success", "unauthorized", "cancelled"] {
      let actionBarrier = StorageModeDiscoveryBarrier()
      let fixture = try makeFixture(
        publishingAssistantService: AIPublishingAssistantService(
          client: AIChatCompletionClient(
            transport: StorageModeConnectionTestTransport(barrier: actionBarrier)
          )
        )
      )
      defer { fixture.remove() }
      let a = fixture.store.activeAIConnectionProfile
      let b = try XCTUnwrap(fixture.store.aiConnectionProfiles.first { $0.id != a.id })
      XCTAssertTrue(fixture.store.ai.saveAPIKey("article-A", connectionProfileID: a.id))
      fixture.store.aiStore.grantAIDataSharingConsent(for: a.config, enablingRemoteAI: true)
      fixture.store.setAIChatKnowledgePolicy(.off)
      let draftID = fixture.store.createDraftWithoutChangingSelection()
      var draft = try XCTUnwrap(fixture.store.draft(for: draftID))
      draft.title = "Article A"
      draft.bodyMarkdown = "# Article A\n\nAn article awaiting a conclusion."
      fixture.store.updateDraft(draft)
      let action = Task { await fixture.store.performAIAction(.draftConclusion, draft: draft) }
      await actionBarrier.waitUntilEntered()
      XCTAssertTrue(fixture.store.isAIActionRunning)

      let discoveryBarrier = StorageModeDiscoveryBarrier()
      let discoveryService = AIModelDiscoveryService(
        transport: StorageModeDiscoveryTransport(barrier: discoveryBarrier),
        cache: AIModelDiscoveryCache()
      )
      if outcome != "unauthorized" {
        XCTAssertTrue(fixture.store.ai.saveAPIKey("models-B", connectionProfileID: b.id))
        fixture.store.aiStore.grantAIDataSharingConsent(for: b.config, enablingRemoteAI: true)
      }
      let discovery = Task {
        try await fixture.store.aiStore.discoverAIModels(
          forConnectionProfileID: b.id, requestedConfig: b.config, service: discoveryService
        )
      }
      if outcome != "unauthorized" {
        await discoveryBarrier.waitUntilEntered()
        if outcome == "cancelled" {
          fixture.store.ai.setCredentialStorageMode(.session, connectionProfileID: b.id)
        }
        await discoveryBarrier.release()
      }
      do {
        let models = try await discovery.value
        XCTAssertEqual(outcome, "success")
        XCTAssertEqual(models.map(\.id), ["test-model"])
      } catch is CancellationError {
        XCTAssertEqual(outcome, "cancelled")
      } catch let error as AIModelDiscoveryError {
        XCTAssertEqual(outcome, "unauthorized")
        XCTAssertEqual(error, .authorizationChanged)
      } catch {
        XCTFail("Unexpected discovery error: \(error)")
      }

      await actionBarrier.release()
      let result = await action.value
      XCTAssertEqual(result?.content, "OK", "outcome=\(outcome)")
      XCTAssertEqual(fixture.store.aiActionResult, result, "outcome=\(outcome)")
      XCTAssertEqual(fixture.store.aiActionMessage, "AI 操作已完成。", "outcome=\(outcome)")
      XCTAssertFalse(fixture.store.isAIActionRunning)
    }
  }

  private func makeFixture(
    legacyMode: AICredentialStorageMode = .keychain,
    connectionTestService: AIConnectionTestService = AIConnectionTestService(),
    publishingAssistantService: AIPublishingAssistantService = AIPublishingAssistantService()
  ) throws -> Fixture {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("AIConnectionCredentialStorageModeTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let suiteName = "AIConnectionCredentialStorageModeTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defaults.set(legacyMode.rawValue, forKey: AICredentialStore.storageModePreferenceKey)
    let keychain = KeychainTokenStore(
      service: suiteName, accountPrefix: "connection-mode-tests", inMemory: true
    )
    let credentialFileURL = directory.appendingPathComponent("AI/credentials.json")
    let credentials = AICredentialStore(
      keychainTokenStore: keychain, localFileURL: credentialFileURL, userDefaults: defaults
    )
    let connections = ["a", "b"].map { name in
      AIConnectionProfile(
        name: name,
        config: AIProviderConfig(
          preset: .custom, baseURL: "https://\(name).example/v1", model: "test-model",
          requiresAPIKey: true
        )
      )
    }
    var site = SiteProfile.defaultProfile
    site.aiConnectionProfileID = connections[0].id
    site.aiProviderConfig = connections[0].config
    let snapshot = WorkbenchSnapshot(
      profiles: [site], aiConnectionProfiles: connections, activeProfileID: site.id,
      drafts: [], releaseRecords: []
    )
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(
        fileURL: directory.appendingPathComponent("workbench.json")),
      initialSnapshotSource: .preloaded(WorkbenchSnapshotLoadResult(snapshot: snapshot)),
      safeMode: true,
      keychainTokenStore: keychain, aiCredentialStore: credentials,
      aiPublishingAssistantService: publishingAssistantService,
      aiConnectionTestService: connectionTestService,
      aiDataSharingConsentStore: AIDataSharingConsentStore(defaults: defaults)
    )
    return Fixture(
      directory: directory, suiteName: suiteName, defaults: defaults, keychain: keychain,
      credentials: credentials, credentialFileURL: credentialFileURL, store: store
    )
  }

  @MainActor
  private struct Fixture {
    let directory: URL
    let suiteName: String
    let defaults: UserDefaults
    let keychain: KeychainTokenStore
    let credentials: AICredentialStore
    let credentialFileURL: URL
    let store: WorkbenchStore

    var snapshot: WorkbenchSnapshot {
      WorkbenchSnapshot(
        profiles: store.profiles, aiConnectionProfiles: store.aiConnectionProfiles,
        activeProfileID: store.activeProfileID, drafts: [], releaseRecords: []
      )
    }

    func reopenedCredentials() -> AICredentialStore {
      AICredentialStore(
        keychainTokenStore: keychain, localFileURL: credentialFileURL, userDefaults: defaults
      )
    }

    func reopenedStore(credentials: AICredentialStore) -> WorkbenchStore {
      WorkbenchStore(
        persistence: WorkbenchPersistence(
          fileURL: directory.appendingPathComponent("reopened.json")),
        initialSnapshotSource: .preloaded(WorkbenchSnapshotLoadResult(snapshot: snapshot)),
        safeMode: true,
        keychainTokenStore: keychain, aiCredentialStore: credentials,
        aiDataSharingConsentStore: AIDataSharingConsentStore(defaults: defaults)
      )
    }

    func remove() {
      defaults.removePersistentDomain(forName: suiteName)
      try? FileManager.default.removeItem(at: directory)
    }
  }
}

private actor StorageModeDiscoveryBarrier {
  private var entered = false
  private var enteredContinuation: CheckedContinuation<Void, Never>?
  private var releaseContinuation: CheckedContinuation<Void, Never>?

  func block() async {
    entered = true
    enteredContinuation?.resume()
    enteredContinuation = nil
    await withCheckedContinuation { releaseContinuation = $0 }
  }

  func waitUntilEntered() async {
    if entered { return }
    await withCheckedContinuation { enteredContinuation = $0 }
  }

  func release() {
    releaseContinuation?.resume()
    releaseContinuation = nil
  }
}

private struct StorageModeDiscoveryTransport: AIModelDiscoveryTransport {
  let barrier: StorageModeDiscoveryBarrier

  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    await barrier.block()
    let response = try XCTUnwrap(
      HTTPURLResponse(
        url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)
    )
    return (Data(#"{"data":[{"id":"test-model"}]}"#.utf8), response)
  }
}

private struct StorageModeConnectionTestTransport: AIChatTransport {
  let barrier: StorageModeDiscoveryBarrier

  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    await barrier.block()
    let response = try XCTUnwrap(
      HTTPURLResponse(
        url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)
    )
    return (Data(#"{"choices":[{"message":{"role":"assistant","content":"OK"}}]}"#.utf8), response)
  }
}
