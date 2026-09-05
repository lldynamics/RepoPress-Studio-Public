import XCTest

@testable import PublishingWorkbenchCore

@MainActor
final class AIConnectionProfileDuplicationTests: XCTestCase {
  func testCopyIsSiteScopedAndNeverReusesOrRemovesOriginalCredentials() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "AIConnectionCopy-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("workbench.json")
    let tokens = KeychainTokenStore(
      service: "AIConnectionCopy-\(UUID())", accountPrefix: "copy-tests", inMemory: true)
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: file), safeMode: true,
      keychainTokenStore: tokens)
    var original = store.activeAIConnectionProfile
    original.config = AIProviderConfig(
      preset: .custom, baseURL: "https://copy.example.invalid/v1",
      model: "original-model", requiresAPIKey: true)
    XCTAssertTrue(store.updateAIConnectionProfile(original))
    let originalSite = store.activeProfile
    var otherSite = originalSite
    otherSite.id = UUID()
    otherSite.name = "Other site"
    store.setProfiles([originalSite, otherSite])
    var legacySite = originalSite
    legacySite.aiConnectionProfileID = nil
    try tokens.saveAIToken("original-shared-test-key", forConnectionProfileID: original.id)
    try tokens.saveAIToken("original-legacy-test-key", for: legacySite)

    let copy = try XCTUnwrap(store.duplicateAIConnectionProfileForActiveSite(original.id))
    XCTAssertNotEqual(copy.id, original.id)
    XCTAssertEqual(copy.config, original.config)
    XCTAssertFalse(copy.canUseLegacyCredentials)
    XCTAssertEqual(store.activeProfile.aiConnectionProfileID, copy.id)
    XCTAssertEqual(store.profiles.first(where: { $0.id == otherSite.id }), otherSite)
    XCTAssertEqual(store.aiConnectionProfile(for: original.id), original)
    XCTAssertFalse(store.aiTokenAvailability.hasToken)
    XCTAssertNil(try tokens.aiToken(forConnectionProfileID: copy.id))

    let reloaded = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: file), safeMode: true,
      keychainTokenStore: tokens)
    XCTAssertEqual(reloaded.activeAIConnectionProfile.id, copy.id)
    XCTAssertFalse(reloaded.activeAIConnectionProfile.canUseLegacyCredentials)
    reloaded.refreshAIKeyAvailability()
    XCTAssertFalse(reloaded.aiTokenAvailability.hasToken)
    XCTAssertTrue(reloaded.saveAIAPIKey("copy-test-key"))
    XCTAssertEqual(try tokens.aiToken(for: legacySite), "original-legacy-test-key")
    reloaded.deleteAIAPIKey()
    XCTAssertEqual(try tokens.aiToken(for: legacySite), "original-legacy-test-key")

    var changedCopy = copy
    changedCopy.config.baseURL = "https://other.example.invalid/v1"
    changedCopy.allowsLegacyCredentialFallback = nil
    XCTAssertTrue(reloaded.updateAIConnectionProfile(changedCopy))
    XCTAssertFalse(reloaded.activeAIConnectionProfile.canUseLegacyCredentials)
    XCTAssertEqual(
      try tokens.aiToken(forConnectionProfileID: original.id), "original-shared-test-key")
    XCTAssertEqual(try tokens.aiToken(for: legacySite), "original-legacy-test-key")
    XCTAssertEqual(reloaded.aiConnectionProfile(for: original.id), original)
    XCTAssertTrue(reloaded.selectAIConnectionProfile(original.id))
    XCTAssertEqual(try tokens.aiToken(for: legacySite), "original-legacy-test-key")
  }

  func testFailedPersistenceRollsBackBothCopyAndSiteBinding() {
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(
        fileURL: URL(fileURLWithPath: "/dev/null/copy-\(UUID()).json")),
      safeMode: true,
      keychainTokenStore: KeychainTokenStore(
        service: "CopyRollback-\(UUID())", accountPrefix: "copy-tests", inMemory: true))
    let profiles = store.profiles
    let connections = store.aiConnectionProfiles
    XCTAssertNil(
      store.duplicateAIConnectionProfileForActiveSite(store.activeAIConnectionProfile.id))
    XCTAssertEqual(store.profiles, profiles)
    XCTAssertEqual(store.aiConnectionProfiles, connections)
    XCTAssertTrue(store.aiActionMessage?.contains("未能保存") == true)
  }

  func testUnknownSelectionAndCapacityLimitDoNotCreateAnUnrestorableCopy() {
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(
        fileURL: URL(fileURLWithPath: "/dev/null/copy-\(UUID()).json")),
      safeMode: true,
      keychainTokenStore: KeychainTokenStore(
        service: "CopyLimit-\(UUID())", accountPrefix: "copy-tests", inMemory: true))
    let original = store.activeAIConnectionProfile
    let profiles = store.profiles
    let connections = store.aiConnectionProfiles
    XCTAssertNil(store.duplicateAIConnectionProfileForActiveSite(UUID()))
    XCTAssertEqual(store.aiConnectionProfiles, connections)
    store.aiConnectionProfiles =
      [original]
      + (1..<64).map {
        AIConnectionProfile.template(named: "Connection \($0)", preset: .local)
      }
    XCTAssertNil(store.duplicateAIConnectionProfileForActiveSite(original.id))
    XCTAssertEqual(store.aiConnectionProfiles.count, 64)
    XCTAssertEqual(store.profiles, profiles)
  }

  func testLegacyConnectionDocumentsRetainCompatibleCredentialResolution() throws {
    let profile = AIConnectionProfile.template(named: "Existing", preset: .local)
    var object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as? [String: Any])
    object.removeValue(forKey: "allowsLegacyCredentialFallback")
    let decoded = try JSONDecoder().decode(
      AIConnectionProfile.self,
      from: JSONSerialization.data(withJSONObject: object))
    XCTAssertTrue(decoded.canUseLegacyCredentials)
  }
}
