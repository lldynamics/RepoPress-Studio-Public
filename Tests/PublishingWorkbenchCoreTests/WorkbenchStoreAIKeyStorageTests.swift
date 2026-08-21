import XCTest

@testable import PublishingWorkbenchCore

@MainActor
final class WorkbenchStoreAIKeyStorageTests: XCTestCase {
  func testFirstSendGrantOpensRemoteGateForOnlyTheConfirmedDestination() throws {
    let suiteName = "WorkbenchStoreAIKeyStorageTests.Consent.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let consentStore = AIDataSharingConsentStore(defaults: defaults)
    consentStore.setRemoteAIEnabled(false)
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: try temporaryPersistenceURL()),
      keychainTokenStore: KeychainTokenStore(
        service: "PersonalSitePublisherMac.Tests.Consent.\(UUID().uuidString)",
        accountPrefix: "consent-tests",
        inMemory: true
      ),
      aiDataSharingConsentStore: consentStore
    )
    var confirmedConfig = AIProviderConfig(preset: .codexAppServer)
    confirmedConfig.applyPresetDefaults()
    // Codex grants are account-bound and cannot be created by the legacy
    // status-less consent API. This test explicitly models the live account
    // that the user confirmed before checking the remote-gate behavior.
    let confirmedAccount = CodexAppServerAccountStatus(
      isAuthenticated: true,
      accountID: "acct-first-send-consent-test",
      accountType: "chatgpt"
    )
    let otherConfig = AIProviderConfig(
      preset: .custom,
      baseURL: "https://api.example.test/v1",
      model: "example-model",
      requiresAPIKey: false
    )

    store.aiStore.grantAIDataSharingConsent(
      for: confirmedConfig,
      enablingRemoteAI: true,
      codexAccountStatus: confirmedAccount
    )

    XCTAssertTrue(consentStore.presentation(for: confirmedConfig).isGranted)
    XCTAssertTrue(consentStore.presentation(for: confirmedConfig).isRemoteAIEnabled)
    XCTAssertFalse(consentStore.presentation(for: otherConfig).isGranted)
  }

  func testEmptyAIBaseURLIsUnconfiguredInsteadOfKeychainFailure() throws {
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: try temporaryPersistenceURL()),
      keychainTokenStore: KeychainTokenStore(
        service: "PersonalSitePublisherMac.Tests.EmptyAIBaseURL.\(UUID().uuidString)",
        accountPrefix: "empty-ai-base-url-tests",
        inMemory: true
      )
    )

    store.updateActiveProfile { profile in
      profile.aiProviderConfig = AIProviderConfig(
        preset: .custom,
        baseURL: "",
        model: "",
        requiresAPIKey: true
      )
    }
    store.refreshAIKeyAvailability()

    XCTAssertEqual(store.aiTokenAvailability.accessState, .missing)
    XCTAssertNil(store.aiTokenAvailability.accessFailureMessage)
    XCTAssertFalse(store.saveAIAPIKey("sk-should-not-save"))
    XCTAssertEqual(store.aiActionMessage, "API Base URL 尚未配置。")
  }

  func testInitializationRestoresExistingAIKeyAvailability() async throws {
    let persistenceURL = try temporaryPersistenceURL()
    let tokenStore = KeychainTokenStore(
      service: "PersonalSitePublisherMac.Tests.AIKeyRestore.\(UUID().uuidString)",
      accountPrefix: "ai-key-restore-tests",
      inMemory: true
    )
    var legacyProfile = SiteProfile.defaultProfile
    legacyProfile.aiConnectionProfileID = nil
    legacyProfile.aiProviderConfig = AIProviderConfig(
      preset: .custom,
      baseURL: "https://api.openai.com/v1",
      model: "gpt-4.1-mini",
      requiresAPIKey: true
    )
    try tokenStore.saveAIToken("persisted-token", for: legacyProfile)

    let restoredStore = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: persistenceURL),
      initialSnapshotSource: .preloaded(
        WorkbenchSnapshotLoadResult(
          snapshot: WorkbenchSnapshot(
            profiles: [legacyProfile],
            activeProfileID: legacyProfile.id,
            drafts: [ArticleDraft.empty(profile: legacyProfile)],
            releaseRecords: []
          )
        )),
      keychainTokenStore: tokenStore
    )
    restoredStore.refreshAIKeyAvailability()

    XCTAssertNotNil(restoredStore.activeProfile.aiConnectionProfileID)
    XCTAssertTrue(restoredStore.aiTokenAvailability.hasToken)
  }

  func testSaveAIAPIKeyStoresTokenAndUpdatesAvailability() throws {
    let persistenceURL = try temporaryPersistenceURL()
    let tokenStore = KeychainTokenStore(
      service: "PersonalSitePublisherMac.Tests.AIKey.\(UUID().uuidString)",
      accountPrefix: "ai-key-tests",
      inMemory: true
    )
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: persistenceURL),
      keychainTokenStore: tokenStore
    )

    store.updateActiveProfile { profile in
      profile.aiProviderConfig = AIProviderConfig(
        preset: .custom,
        baseURL: "https://api.openai.com/v1",
        model: "gpt-4.1-mini",
        requiresAPIKey: true
      )
    }
    store.saveAIAPIKey("  sk-test-token  ")

    XCTAssertEqual(store.aiActionMessage, "AI API Key 已保存到 Keychain。")
    XCTAssertTrue(store.aiTokenAvailability.hasToken)
    XCTAssertEqual(try tokenStore.aiToken(for: store.activeProfile), "sk-test-token")
  }

  func testDeleteAIAPIKeyClearsStoredTokenAndAvailability() throws {
    let persistenceURL = try temporaryPersistenceURL()
    let tokenStore = KeychainTokenStore(
      service: "PersonalSitePublisherMac.Tests.AIKey.\(UUID().uuidString)",
      accountPrefix: "ai-key-tests",
      inMemory: true
    )
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: persistenceURL),
      keychainTokenStore: tokenStore
    )
    store.updateActiveProfile { profile in
      profile.aiProviderConfig = AIProviderConfig(
        preset: .custom,
        baseURL: "https://api.openai.com/v1",
        model: "gpt-4.1-mini",
        requiresAPIKey: true
      )
    }
    store.saveAIAPIKey("sk-test-token")

    store.deleteAIAPIKey()

    XCTAssertEqual(store.aiActionMessage, "AI API Key 已删除。")
    XCTAssertEqual(store.aiChatMessage, "AI API Key 已删除，请重新配置后再发送消息。")
    XCTAssertFalse(store.aiTokenAvailability.hasToken)
    XCTAssertNil(try tokenStore.aiToken(for: store.activeProfile))
  }

  func testChangingAIEndpointRequiresTokenToBeSavedAgain() throws {
    let persistenceURL = try temporaryPersistenceURL()
    let tokenStore = KeychainTokenStore(
      service: "PersonalSitePublisherMac.Tests.AIOrigin.\(UUID().uuidString)",
      accountPrefix: "ai-origin-tests",
      inMemory: true
    )
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: persistenceURL),
      keychainTokenStore: tokenStore
    )
    store.updateActiveProfile { profile in
      profile.aiProviderConfig = AIProviderConfig(
        preset: .custom,
        baseURL: "https://api.openai.com/v1",
        model: "gpt-4.1-mini",
        requiresAPIKey: true
      )
    }
    store.saveAIAPIKey("deepseek-token")
    XCTAssertTrue(store.aiTokenAvailability.hasToken)

    store.updateActiveProfile { profile in
      profile.aiProviderConfig.baseURL = "https://ai-proxy.example/v1"
    }
    store.refreshAIKeyAvailability()

    XCTAssertFalse(store.aiTokenAvailability.hasToken)
    XCTAssertNil(try tokenStore.aiToken(for: store.activeProfile))
  }

  func testSwitchingProfilesRefreshesAIKeyAvailabilityAutomatically() throws {
    let persistenceURL = try temporaryPersistenceURL()
    let tokenStore = KeychainTokenStore(
      service: "PersonalSitePublisherMac.Tests.AIKeyProfileSwitch.\(UUID().uuidString)",
      accountPrefix: "ai-key-profile-switch-tests",
      inMemory: true
    )
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: persistenceURL),
      keychainTokenStore: tokenStore
    )
    let originalProfileID = store.activeProfileID
    store.updateActiveProfile { profile in
      profile.aiProviderConfig = AIProviderConfig(
        preset: .custom,
        baseURL: "https://api.openai.com/v1",
        model: "gpt-4.1-mini",
        requiresAPIKey: true
      )
    }
    store.saveAIAPIKey("original-profile-token")
    XCTAssertTrue(store.aiTokenAvailability.hasToken)

    let secondProfile = store.createProfile(named: "Second")
    XCTAssertFalse(store.aiTokenAvailability.hasToken)

    store.selectProfile(originalProfileID)
    XCTAssertTrue(store.aiTokenAvailability.hasToken)

    store.selectProfile(secondProfile.id)
    XCTAssertFalse(store.aiTokenAvailability.hasToken)
  }

  func testSuccessfulConnectionSynchronizesAvailabilityAndChatStatus() async throws {
    let persistenceURL = try temporaryPersistenceURL()
    let tokenStore = KeychainTokenStore(
      service: "PersonalSitePublisherMac.Tests.AIKeyConnectionSync.\(UUID().uuidString)",
      accountPrefix: "ai-key-connection-sync-tests",
      inMemory: true
    )
    let credentialStore = AICredentialStore(keychainTokenStore: tokenStore)
    let transport = RecordingAIChatTransport(
      data: Data(
        """
        {
          "model": "deepseek-test",
          "choices": [{"message":{"role":"assistant","content":"OK"}}]
        }
        """.utf8),
      statusCode: 200
    )
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: persistenceURL),
      keychainTokenStore: tokenStore,
      aiCredentialStore: credentialStore,
      aiConnectionTestService: AIConnectionTestService(
        client: AIChatCompletionClient(transport: transport)
      )
    )
    store.updateActiveProfile { profile in
      profile.aiProviderConfig = AIProviderConfig(
        preset: .custom,
        baseURL: "https://api.openai.com/v1",
        model: "gpt-4.1-mini",
        requiresAPIKey: true
      )
    }
    try credentialStore.saveToken(
      "explicitly-resaved-token",
      forConnectionProfileID: store.activeAIConnectionProfile.id,
      legacyProfile: store.activeProfile
    )
    store.aiStore.grantAIDataSharingConsent()
    store.setAIChatMessage("AI 讨论失败：请先在 Settings 的 AI 页保存 API Key。")
    XCTAssertFalse(store.aiTokenAvailability.hasToken)

    let report = await store.testAIConnection()

    XCTAssertNotNil(report)
    XCTAssertTrue(store.aiTokenAvailability.hasToken)
    XCTAssertEqual(store.aiChatMessage, "AI 连接正常，可以发送消息。")
  }

  private func temporaryPersistenceURL() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("workbench.json")
  }
}
