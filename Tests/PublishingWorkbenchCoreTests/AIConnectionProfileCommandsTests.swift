import Security
import XCTest
@testable import PublishingWorkbenchCore

@MainActor
final class AIConnectionProfileCommandsTests: XCTestCase {
  func testUpdatingUnknownConnectionReportsFailureWithoutMutation() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: directory.appendingPathComponent("workbench.json")),
      safeMode: true,
      keychainTokenStore: testTokenStore()
    )
    let originalConnections = store.aiConnectionProfiles
    var unknown = store.activeAIConnectionProfile
    unknown.id = UUID()
    unknown.config.model = "must-not-be-applied"

    XCTAssertFalse(store.updateAIConnectionProfile(unknown))
    XCTAssertEqual(store.aiConnectionProfiles, originalConnections)
  }

  func testChangingConnectionDestinationDeletesSharedAPIKeyBeforeUpdate() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let tokenStore = testTokenStore()
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: directory.appendingPathComponent("workbench.json")),
      safeMode: true,
      keychainTokenStore: tokenStore
    )
    var initialConnection = store.activeAIConnectionProfile
    initialConnection.config = configuredTestProvider()
    store.updateAIConnectionProfile(initialConnection)
    let connectionID = store.activeAIConnectionProfile.id
    XCTAssertTrue(store.saveAIAPIKey("destination-secret"))

    var connection = store.activeAIConnectionProfile
    connection.config.baseURL = "https://replacement.example/v1"
    XCTAssertTrue(store.updateAIConnectionProfile(connection))

    XCTAssertEqual(store.activeAIConnectionProfile.config.baseURL, "https://replacement.example/v1")
    XCTAssertNil(try tokenStore.aiToken(forConnectionProfileID: connectionID))
    XCTAssertFalse(store.aiTokenAvailability.hasToken)
    XCTAssertEqual(
      store.aiActionMessage,
      "服务商或 API 地址已更改，旧 API Key 已移除，请重新保存。"
    )
  }

  func testChangingConnectionPresetDeletesSharedAPIKeyEvenAtSameDestination() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let tokenStore = testTokenStore()
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: directory.appendingPathComponent("workbench.json")),
      safeMode: true,
      keychainTokenStore: tokenStore
    )
    var initialConnection = store.activeAIConnectionProfile
    initialConnection.config = AIProviderConfig(
      preset: .deepSeek,
      baseURL: AIProviderPreset.deepSeek.defaultBaseURL,
      model: AIProviderPreset.deepSeek.defaultModel,
      requiresAPIKey: true
    )
    store.updateAIConnectionProfile(initialConnection)
    let connectionID = store.activeAIConnectionProfile.id
    XCTAssertTrue(store.saveAIAPIKey("preset-secret"))

    var connection = store.activeAIConnectionProfile
    connection.config.preset = .custom
    store.updateAIConnectionProfile(connection)

    XCTAssertEqual(store.activeAIConnectionProfile.config.preset, .custom)
    XCTAssertNil(try tokenStore.aiToken(forConnectionProfileID: connectionID))
  }

  func testChangingOnlyConnectionModelKeepsSharedAPIKey() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let tokenStore = testTokenStore()
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: directory.appendingPathComponent("workbench.json")),
      safeMode: true,
      keychainTokenStore: tokenStore
    )
    var initialConnection = store.activeAIConnectionProfile
    initialConnection.config = configuredTestProvider()
    store.updateAIConnectionProfile(initialConnection)
    let connectionID = store.activeAIConnectionProfile.id
    XCTAssertTrue(store.saveAIAPIKey("model-secret"))

    var connection = store.activeAIConnectionProfile
    connection.config.model = "replacement-model"
    store.updateAIConnectionProfile(connection)

    XCTAssertEqual(store.activeAIConnectionProfile.config.model, "replacement-model")
    XCTAssertEqual(
      try tokenStore.aiToken(forConnectionProfileID: connectionID),
      "model-secret"
    )
    XCTAssertTrue(store.aiTokenAvailability.hasToken)
  }

  func testLegacyInlineConfigEditUpdatesSelectedReusableConnection() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("AIConnectionProfileCommandsTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: directory.appendingPathComponent("workbench.json")),
      safeMode: true,
      keychainTokenStore: testTokenStore()
    )
    let connectionID = store.activeAIConnectionProfile.id
    var profile = store.activeProfile
    profile.aiProviderConfig = AIProviderConfig(
      preset: .custom,
      baseURL: "https://ai.example/v1",
      model: "test-model",
      requiresAPIKey: false
    )

    store.updateActiveProfile(profile)

    XCTAssertEqual(store.activeAIConnectionProfile.id, connectionID)
    XCTAssertEqual(store.activeAIConnectionProfile.config, profile.aiProviderConfig)
    XCTAssertEqual(
      store.aiConnectionProfiles.first(where: { $0.id == connectionID })?.config,
      profile.aiProviderConfig
    )
  }

  func testDeleteRequiresAnUnusedAlternativeConnectionProfile() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("AIConnectionProfileCommandsTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let tokenStore = testTokenStore()
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: directory.appendingPathComponent("workbench.json")),
      safeMode: true,
      keychainTokenStore: tokenStore
    )
    let selectedID = store.activeAIConnectionProfile.id

    XCTAssertFalse(store.canDeleteAIConnectionProfile(selectedID))
    XCTAssertFalse(store.deleteAIConnectionProfile(selectedID))
    XCTAssertTrue(store.aiConnectionProfiles.contains { $0.id == selectedID })

    let unused = store.createAIConnectionProfile(named: "备用连接", preset: .custom)
    XCTAssertTrue(store.canDeleteAIConnectionProfile(unused.id))
    try tokenStore.saveAIToken("unused-secret", forConnectionProfileID: unused.id)
    XCTAssertEqual(
      try tokenStore.aiToken(forConnectionProfileID: unused.id),
      "unused-secret"
    )

    XCTAssertTrue(store.deleteAIConnectionProfile(unused.id))
    XCTAssertFalse(store.aiConnectionProfiles.contains { $0.id == unused.id })
    XCTAssertNil(try tokenStore.aiToken(forConnectionProfileID: unused.id))
    XCTAssertEqual(store.activeAIConnectionProfile.id, selectedID)
    XCTAssertEqual(store.aiActionMessage, "AI 连接及其 API Key 已删除。")
  }

  func testDeleteKeepsConnectionMetadataWhenKeychainDeletionFails() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let tokenStore = KeychainTokenStore(
      service: "AIConnectionProfileCommandsTests.\(UUID().uuidString)",
      accountPrefix: "ai-connection-command-tests",
      inMemory: true,
      deletionStatusOverrideForTesting: { _ in errSecAuthFailed }
    )
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: directory.appendingPathComponent("workbench.json")),
      safeMode: true,
      keychainTokenStore: tokenStore
    )
    let unused = store.createAIConnectionProfile(named: "删除失败连接", preset: .custom)
    try tokenStore.saveAIToken("must-survive", forConnectionProfileID: unused.id)

    XCTAssertFalse(store.deleteAIConnectionProfile(unused.id))

    XCTAssertTrue(store.aiConnectionProfiles.contains { $0.id == unused.id })
    XCTAssertEqual(
      try tokenStore.aiToken(forConnectionProfileID: unused.id),
      "must-survive"
    )
    XCTAssertTrue(store.aiActionMessage?.contains("AI 连接未删除") == true)
    XCTAssertTrue(store.aiActionMessage?.contains("Keychain") == true)
  }

  func testSelectingAnotherConnectionDeletesLegacySiteCredentialBeforeSwitch() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let tokenStore = testTokenStore()
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: directory.appendingPathComponent("workbench.json")),
      safeMode: true,
      keychainTokenStore: tokenStore
    )
    var initial = store.activeAIConnectionProfile
    initial.config = configuredTestProvider()
    XCTAssertTrue(store.updateAIConnectionProfile(initial))
    var legacyProfile = store.activeProfile
    legacyProfile.aiConnectionProfileID = nil
    try tokenStore.saveAIToken("legacy-site-key", for: legacyProfile)

    var replacement = store.createAIConnectionProfile(named: "新连接", preset: .custom)
    replacement.config = AIProviderConfig(
      preset: .custom,
      baseURL: "https://replacement.example/v1",
      model: "replacement-model",
      requiresAPIKey: true
    )
    XCTAssertTrue(store.updateAIConnectionProfile(replacement))
    XCTAssertTrue(store.selectAIConnectionProfile(replacement.id))

    XCTAssertEqual(store.activeAIConnectionProfile.id, replacement.id)
    XCTAssertNil(try tokenStore.aiToken(for: legacyProfile))
  }

  func testSelectingAnotherConnectionIsCancelledWhenLegacyCleanupFails() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let tokenStore = testTokenStoreFailingLegacyDeletion()
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: directory.appendingPathComponent("workbench.json")),
      safeMode: true,
      keychainTokenStore: tokenStore
    )
    var initial = store.activeAIConnectionProfile
    initial.config = configuredTestProvider()
    XCTAssertTrue(store.updateAIConnectionProfile(initial))
    let initialConnectionID = store.activeAIConnectionProfile.id
    var legacyProfile = store.activeProfile
    legacyProfile.aiConnectionProfileID = nil
    try tokenStore.saveAIToken("legacy-site-key", for: legacyProfile)
    let replacement = store.createAIConnectionProfile(named: "新连接", preset: .custom)

    XCTAssertFalse(store.selectAIConnectionProfile(replacement.id))

    XCTAssertEqual(store.activeAIConnectionProfile.id, initialConnectionID)
    XCTAssertEqual(try tokenStore.aiToken(for: legacyProfile), "legacy-site-key")
    XCTAssertTrue(store.aiActionMessage?.contains("AI 连接未切换") == true)
  }

  func testConnectionEditKeepsSharedKeyWhenLegacyCleanupFails() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let tokenStore = testTokenStoreFailingLegacyDeletion()
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: directory.appendingPathComponent("workbench.json")),
      safeMode: true,
      keychainTokenStore: tokenStore
    )
    var initial = store.activeAIConnectionProfile
    initial.config = configuredTestProvider()
    XCTAssertTrue(store.updateAIConnectionProfile(initial))
    let connectionID = store.activeAIConnectionProfile.id
    try tokenStore.saveAIToken("shared-key", forConnectionProfileID: connectionID)
    var legacyProfile = store.activeProfile
    legacyProfile.aiConnectionProfileID = nil
    try tokenStore.saveAIToken("legacy-site-key", for: legacyProfile)

    var updated = store.activeAIConnectionProfile
    updated.config.baseURL = "https://changed.example/v1"
    XCTAssertFalse(store.updateAIConnectionProfile(updated))

    XCTAssertEqual(store.activeAIConnectionProfile.config.baseURL, "https://initial.example/v1")
    XCTAssertEqual(
      try tokenStore.aiToken(forConnectionProfileID: connectionID),
      "shared-key"
    )
  }

  func testConnectionDeletionFeedbackResolvesInEnglish() {
    let english = Locale(identifier: "en")
    XCTAssertEqual(
      CoreL10n.text("AI 连接及其 API Key 已删除。", locale: english),
      "The AI connection and its API key were deleted."
    )
    XCTAssertEqual(
      CoreL10n.format(
        "AI 连接未删除：关联的 API Key 删除失败。请检查 Keychain 权限后重试。%@",
        locale: english,
        arguments: ["Access denied"]
      ),
      "The AI connection was not deleted because its API key could not be removed. "
        + "Check Keychain access and try again. Access denied"
    )
  }

  private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("AIConnectionProfileCommandsTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  private func testTokenStore() -> KeychainTokenStore {
    KeychainTokenStore(
      service: "AIConnectionProfileCommandsTests.\(UUID().uuidString)",
      accountPrefix: "ai-connection-command-tests",
      inMemory: true
    )
  }

  private func testTokenStoreFailingLegacyDeletion() -> KeychainTokenStore {
    KeychainTokenStore(
      service: "AIConnectionProfileCommandsTests.\(UUID().uuidString)",
      accountPrefix: "ai-connection-command-tests",
      inMemory: true,
      deletionStatusOverrideForTesting: { account in
        account.contains("-origin-") ? errSecAuthFailed : nil
      }
    )
  }

  private func configuredTestProvider() -> AIProviderConfig {
    AIProviderConfig(
      preset: .custom,
      baseURL: "https://initial.example/v1",
      model: "initial-model",
      requiresAPIKey: true
    )
  }
}
