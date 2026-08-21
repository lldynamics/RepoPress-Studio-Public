import Security
import XCTest

@testable import PublishingWorkbenchCore

@MainActor
final class TokenCredentialScopeTests: XCTestCase {
  func testDebugCredentialServicesAreIsolatedFromReleaseKeychainItems() {
    #if DEBUG
      XCTAssertEqual(
        KeychainCredentialServices.ai, "PersonalSitePublisherMac.LocalDevelopment.AIProvider")
      XCTAssertEqual(
        KeychainCredentialServices.repository,
        "PersonalSitePublisherMac.LocalDevelopment.RepositoryProvider")
      XCTAssertEqual(
        KeychainCredentialServices.deployment,
        "PersonalSitePublisherMac.LocalDevelopment.DeploymentProvider")
    #else
      XCTAssertEqual(KeychainCredentialServices.ai, "PersonalSitePublisherMac.AIProvider")
      XCTAssertEqual(
        KeychainCredentialServices.repository, "PersonalSitePublisherMac.RepositoryProvider")
      XCTAssertEqual(
        KeychainCredentialServices.deployment, "PersonalSitePublisherMac.DeploymentProvider")
    #endif
  }

  func testMissingKeychainErrorExplainsHowToRestoreTheLoginKeychainContext() {
    let error = KeychainTokenStoreError.unhandledStatus(errSecNoSuchKeychain)

    XCTAssertTrue(
      error.localizedDescription.contains("\(errSecNoSuchKeychain)"),
      "Actual error: \(error.localizedDescription)"
    )
    XCTAssertTrue(error.recoveryHint?.contains("登录钥匙串") == true)
    XCTAssertEqual(error.recoverySuggestion, error.recoveryHint)
  }

  func testLegacyLocalBuildKeychainErrorsExplainHowToRecover() {
    for status in [errSecInvalidOwnerEdit, OSStatus(-25253)] {
      let error = KeychainTokenStoreError.unhandledStatus(status)

      XCTAssertTrue(
        error.localizedDescription.contains("\(status)"),
        "Actual error: \(error.localizedDescription)"
      )
      XCTAssertTrue(error.recoveryHint?.contains("旧构建") == true)
      XCTAssertTrue(error.recoveryHint?.contains("PersonalSitePublisher") == true)
      XCTAssertTrue(KeychainTokenStore.isRecoverableDeletionOwnershipStatus(status))
    }
    XCTAssertFalse(KeychainTokenStore.isRecoverableDeletionOwnershipStatus(errSecAuthFailed))
  }

  func testTokenAvailabilityDistinguishesMissingFromAccessFailure() throws {
    let available = KeychainTokenAvailability(hasToken: true)
    let missing = KeychainTokenAvailability(hasToken: false)
    let failure = KeychainTokenAvailability(
      accessFailure: KeychainTokenStoreError.unhandledStatus(errSecAuthFailed)
    )

    XCTAssertEqual(available.accessState, .available)
    XCTAssertEqual(missing.accessState, .missing)
    XCTAssertEqual(failure.accessState, .accessFailed)
    XCTAssertFalse(failure.hasToken)
    XCTAssertTrue(failure.accessFailureMessage?.contains("\(errSecAuthFailed)") == true)

    let legacyData = Data(#"{"hasToken":false,"updatedAt":null}"#.utf8)
    let decoded = try JSONDecoder().decode(
      KeychainTokenAvailability.self,
      from: legacyData
    )
    XCTAssertEqual(decoded.accessState, .missing)
    XCTAssertNil(decoded.accessFailureMessage)
  }

  func testPassiveAvailabilityQueryNeverRequestsSecretData() {
    let tokenStore = KeychainTokenStore(
      service: "PersonalSitePublisherMac.Tests.PassiveAvailability",
      accountPrefix: "passive-availability"
    )

    let query = tokenStore.availabilityQuery(account: "passive-availability-test")

    XCTAssertEqual(query[kSecReturnAttributes as String] as? Bool, true)
    XCTAssertNil(query[kSecReturnData as String])
    XCTAssertEqual(
      query[kSecMatchLimit as String] as? String,
      kSecMatchLimitOne as String
    )
  }

  func testClearedLegacyCredentialMetadataReportsMissingWithoutReadingSecretData() throws {
    let updatedAt = Date(timeIntervalSince1970: 1_700_000_000)
    let clearedAttributes: [String: Any] = [
      kSecAttrGeneric as String: KeychainTokenStore.clearedCredentialMetadataMarker,
      kSecAttrModificationDate as String: updatedAt,
    ]

    let clearedAvailability = KeychainTokenStore.availability(from: clearedAttributes)
    let ordinaryAvailability = KeychainTokenStore.availability(from: [
      kSecAttrGeneric as String: Data(),
      kSecAttrModificationDate as String: updatedAt,
    ])

    XCTAssertFalse(clearedAvailability.hasToken)
    XCTAssertNil(clearedAvailability.updatedAt)
    XCTAssertTrue(ordinaryAvailability.hasToken)
    XCTAssertEqual(ordinaryAvailability.updatedAt, updatedAt)
    XCTAssertNil(try KeychainTokenStore.tokenString(from: Data()))
  }

  func testEmptyCredentialOriginUsesExplicitUnconfiguredMessage() {
    let error = KeychainTokenStoreError.invalidCredentialOrigin("")

    XCTAssertEqual(error.localizedDescription, "API Base URL 尚未配置。")
    XCTAssertFalse(error.localizedDescription.hasSuffix(":"))
  }

  func testStoresPreserveCredentialReadFailureInsteadOfReportingMissingToken() throws {
    let persistenceURL = try temporaryPersistenceURL(prefix: "KeychainAccessFailure")
    let aiTokenStore = KeychainTokenStore(
      service: "PersonalSitePublisherMac.Tests.AIAccessFailure",
      accountPrefix: "ai-access-failure",
      inMemory: true
    )
    let repositoryTokenStore = KeychainTokenStore(
      service: "PersonalSitePublisherMac.Tests.RepositoryAccessFailure",
      accountPrefix: "repository-access-failure",
      inMemory: true
    )
    let deploymentTokenStore = KeychainTokenStore(
      service: "PersonalSitePublisherMac.Tests.DeploymentAccessFailure",
      accountPrefix: "deployment-access-failure",
      inMemory: true
    )
    var profile = SiteProfile.defaultProfile
    profile.repositoryBaseURL = "http://insecure.example.test"
    profile.aiProviderConfig.baseURL = "http://insecure.example.test"
    profile.aiProviderConfig.requiresAPIKey = true
    profile.deploymentProvider = .githubPages
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: persistenceURL),
      initialSnapshotSource: .preloaded(
        WorkbenchSnapshotLoadResult(
          snapshot: WorkbenchSnapshot(
            profiles: [profile],
            activeProfileID: profile.id,
            drafts: [ArticleDraft.empty(profile: profile)],
            releaseRecords: []
          )
        )),
      keychainTokenStore: aiTokenStore,
      repositoryTokenStore: repositoryTokenStore,
      deploymentTokenStore: deploymentTokenStore
    )

    store.refreshRepositoryTokenAvailability(updatesMessage: true)
    store.refreshDeploymentTokenAvailability()
    store.refreshAIKeyAvailability()

    XCTAssertEqual(store.repositoryTokenAvailability.accessState, .accessFailed)
    XCTAssertEqual(store.deploymentTokenAvailability.accessState, .accessFailed)
    XCTAssertEqual(store.aiTokenAvailability.accessState, .accessFailed)
    XCTAssertFalse(store.publishActionMessage?.contains("未配置") == true)
    XCTAssertTrue(store.publishActionMessage?.contains("读取失败") == true)
    XCTAssertTrue(store.deploymentStatusMessage?.contains("读取失败") == true)
  }

  func testAIPresentationsExposeKeychainFailureInsteadOfMissingKey() throws {
    let config = AIProviderConfig(
      preset: .custom,
      baseURL: "https://api.openai.com/v1",
      model: "gpt-4.1-mini",
      requiresAPIKey: true
    )
    let failure = KeychainTokenAvailability(
      accessFailure: KeychainTokenStoreError.unhandledStatus(errSecInteractionNotAllowed)
    )

    let chatIssue = try XCTUnwrap(
      AIPublishingChatConversationPresentation.configurationIssue(
        config: config,
        aiTokenAvailability: failure,
        grade: .standard,
        selectedModel: config.normalizedModel
      )
    )
    XCTAssertTrue(chatIssue.contains("读取失败"))
    XCTAssertFalse(chatIssue.contains("未保存"))

    let connection = AISettingsConnectionPresentationService.presentation(
      config: config,
      tokenAvailability: failure,
      report: nil
    )
    XCTAssertTrue(connection.title.contains("读取失败"))

    let image = AIImageTextGenerationAvailabilityService.presentation(
      targetCount: 1,
      isGenerating: false,
      aiProviderConfig: config,
      aiTokenAvailability: failure
    )
    XCTAssertFalse(image.isEnabled)
    XCTAssertTrue(image.unavailableReason?.contains("读取失败") == true)
  }

  func testKeychainScopesKeepRepositoryAndDeploymentTokensSeparate() throws {
    let tokenStore = KeychainTokenStore(
      service: "PersonalSitePublisherMac.Tests.TokenScope",
      accountPrefix: "token-scope",
      inMemory: true
    )
    var profile = SiteProfile.defaultProfile
    profile.id = UUID()

    try tokenStore.saveToken("github-pat", for: profile, scope: .repository(.github))
    try tokenStore.saveToken("vercel-token", for: profile, scope: .deployment(.vercel))

    XCTAssertEqual(try tokenStore.token(for: profile, scope: .repository(.github)), "github-pat")
    XCTAssertEqual(try tokenStore.token(for: profile, scope: .deployment(.vercel)), "vercel-token")
    XCTAssertNil(try tokenStore.token(for: profile, scope: .deployment(.netlify)))
  }

  func testLegacyTokenMigratesOnlyToRequestedScopedCredential() throws {
    let tokenStore = KeychainTokenStore(
      service: "PersonalSitePublisherMac.Tests.TokenMigration",
      accountPrefix: "token-migration",
      inMemory: true
    )
    var profile = SiteProfile.defaultProfile
    profile.id = UUID()
    try tokenStore.saveToken("legacy-token", for: profile)

    XCTAssertTrue(try tokenStore.migrateLegacyToken(for: profile, to: .repository(.github)))
    XCTAssertEqual(try tokenStore.token(for: profile, scope: .repository(.github)), "legacy-token")
    XCTAssertNil(try tokenStore.token(for: profile))
    XCTAssertNil(try tokenStore.token(for: profile, scope: .deployment(.githubPages)))
  }

  func testRepositoryLegacyMigrationCannotFanOutOrReviveAfterDeletion() throws {
    let tokenStore = KeychainTokenStore(
      service: "PersonalSitePublisherMac.Tests.RepositoryLegacyMove",
      accountPrefix: "repository-legacy-move",
      inMemory: true
    )
    var profile = SiteProfile.defaultProfile
    profile.id = UUID()
    profile.repositoryProvider = .github
    try tokenStore.saveToken("legacy-repository-token", for: profile)

    XCTAssertNil(try tokenStore.repositoryToken(for: profile))
    XCTAssertFalse(try tokenStore.repositoryTokenAvailability(for: profile).hasToken)

    try tokenStore.saveRepositoryToken("repository-token", for: profile)
    XCTAssertEqual(try tokenStore.repositoryToken(for: profile), "repository-token")
    XCTAssertNil(try tokenStore.token(for: profile))
    XCTAssertTrue(try tokenStore.repositoryTokenAvailability(for: profile).hasToken)

    try tokenStore.deleteRepositoryToken(for: profile)
    XCTAssertFalse(try tokenStore.repositoryTokenAvailability(for: profile).hasToken)
    XCTAssertNil(try tokenStore.repositoryToken(for: profile))

    profile.repositoryProvider = .gitlab
    XCTAssertNil(try tokenStore.repositoryToken(for: profile))
    XCTAssertFalse(try tokenStore.repositoryTokenAvailability(for: profile).hasToken)
    XCTAssertNil(try tokenStore.token(for: profile, scope: .repository(.github)))
    XCTAssertNil(try tokenStore.token(for: profile, scope: .repository(.gitlab)))
  }

  func testRepositoryDeleteAlsoRemovesLegacyCredentialLeftByOlderRelease() throws {
    let tokenStore = KeychainTokenStore(
      service: "PersonalSitePublisherMac.Tests.RepositoryLegacyCleanup",
      accountPrefix: "repository-legacy-cleanup",
      inMemory: true
    )
    var profile = SiteProfile.defaultProfile
    profile.id = UUID()
    profile.repositoryProvider = .github
    try tokenStore.saveRepositoryToken("scoped-token", for: profile)
    try tokenStore.saveToken("stale-legacy-token", for: profile)

    try tokenStore.deleteRepositoryToken(for: profile)

    XCTAssertNil(try tokenStore.token(for: profile))
    XCTAssertNil(try tokenStore.repositoryToken(for: profile))
    XCTAssertFalse(try tokenStore.repositoryTokenAvailability(for: profile).hasToken)
  }

  func testRepositoryAndDeploymentCredentialsAreBoundToOrigin() throws {
    let tokenStore = KeychainTokenStore(
      service: "PersonalSitePublisherMac.Tests.OriginBinding",
      accountPrefix: "origin-binding",
      inMemory: true
    )
    var profile = SiteProfile.defaultProfile
    profile.id = UUID()
    profile.repositoryProvider = .github
    profile.repositoryBaseURL = "https://api.github.com"
    try tokenStore.saveRepositoryToken("github-token", for: profile)
    try tokenStore.saveToken(
      "vercel-token",
      for: profile,
      scope: .deployment(.vercel),
      originURLText: "https://api.vercel.com"
    )

    XCTAssertEqual(try tokenStore.repositoryToken(for: profile), "github-token")
    profile.repositoryBaseURL = "https://github-enterprise.example/api/v3"
    XCTAssertNil(try tokenStore.repositoryToken(for: profile))
    XCTAssertNil(
      try tokenStore.token(
        for: profile,
        scope: .deployment(.vercel),
        originURLText: "https://proxy.example"
      ))
    XCTAssertEqual(
      try tokenStore.token(
        for: profile,
        scope: .deployment(.vercel),
        originURLText: "https://api.vercel.com/v2"
      ), "vercel-token")
  }

  func testInMemoryBackendSupportsConcurrentMultiScopeReadWriteAndDelete() throws {
    let tokenStore = KeychainTokenStore(
      service: "PersonalSitePublisherMac.Tests.ConcurrentTokenScope",
      accountPrefix: "concurrent-token-scope",
      inMemory: true
    )
    var concurrentProfile = SiteProfile.defaultProfile
    concurrentProfile.id = UUID()
    let profile = concurrentProfile
    let credentials = [
      ConcurrentTokenCredential(name: "ai", scope: nil),
      ConcurrentTokenCredential(name: "repository-github", scope: .repository(.github)),
      ConcurrentTokenCredential(name: "repository-gitlab", scope: .repository(.gitlab)),
      ConcurrentTokenCredential(name: "deployment-vercel", scope: .deployment(.vercel)),
      ConcurrentTokenCredential(name: "deployment-netlify", scope: .deployment(.netlify)),
    ]
    let failures = ConcurrentTokenFailureRecorder()

    let mixedRoundCount = 160
    DispatchQueue.concurrentPerform(iterations: mixedRoundCount * credentials.count) {
      operationIndex in
      let credentialIndex = operationIndex % credentials.count
      let round = operationIndex / credentials.count
      let credential = credentials[credentialIndex]
      let token = credential.token(round: round)

      do {
        switch round % 4 {
        case 0:
          try credential.save(token, in: tokenStore, for: profile)
        case 1:
          _ = try credential.read(from: tokenStore, for: profile)
        case 2:
          try credential.delete(from: tokenStore, for: profile)
        default:
          _ = try credential.availability(in: tokenStore, for: profile)
        }

        if let observed = try credential.read(from: tokenStore, for: profile),
          !observed.hasPrefix("\(credential.name)-round-")
        {
          failures.record("\(credential.name) read unexpected token: \(observed)")
        }
      } catch {
        failures.record("\(credential.name) operation failed: \(error)")
      }
    }
    XCTAssertTrue(failures.messages.isEmpty, failures.messages.joined(separator: "\n"))

    let finalWriteRoundCount = 96
    DispatchQueue.concurrentPerform(iterations: finalWriteRoundCount * credentials.count) {
      operationIndex in
      let credentialIndex = operationIndex % credentials.count
      let round = operationIndex / credentials.count
      let credential = credentials[credentialIndex]
      do {
        try credential.save(credential.token(round: round), in: tokenStore, for: profile)
      } catch {
        failures.record("\(credential.name) final write failed: \(error)")
      }
    }

    for credential in credentials {
      let writtenTokens = Set((0..<finalWriteRoundCount).map(credential.token(round:)))
      let observed = try XCTUnwrap(credential.read(from: tokenStore, for: profile))
      XCTAssertTrue(
        writtenTokens.contains(observed),
        "\(credential.name) ended with a value that was never written")
      XCTAssertTrue(try credential.availability(in: tokenStore, for: profile).hasToken)
    }
    XCTAssertTrue(failures.messages.isEmpty, failures.messages.joined(separator: "\n"))

    let deleteRoundCount = 64
    DispatchQueue.concurrentPerform(iterations: deleteRoundCount * credentials.count) {
      operationIndex in
      let credential = credentials[operationIndex % credentials.count]
      do {
        try credential.delete(from: tokenStore, for: profile)
      } catch {
        failures.record("\(credential.name) delete failed: \(error)")
      }
    }

    for credential in credentials {
      XCTAssertNil(try credential.read(from: tokenStore, for: profile))
      XCTAssertFalse(try credential.availability(in: tokenStore, for: profile).hasToken)
    }
    XCTAssertTrue(failures.messages.isEmpty, failures.messages.joined(separator: "\n"))
  }

  func testDeploymentAvailabilityDoesNotReuseRepositoryToken() throws {
    let repositoryTokenStore = KeychainTokenStore(
      service: "PersonalSitePublisherMac.Tests.RepositoryToken",
      accountPrefix: "repository-token",
      inMemory: true
    )
    let deploymentTokenStore = KeychainTokenStore(
      service: "PersonalSitePublisherMac.Tests.DeploymentToken",
      accountPrefix: "deployment-token",
      inMemory: true
    )
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: try temporaryPersistenceURL()),
      repositoryTokenStore: repositoryTokenStore,
      deploymentTokenStore: deploymentTokenStore
    )
    store.updateActiveProfile { profile in
      profile.deploymentProvider = .vercel
      profile.deploymentProjectID = "personal-site"
    }

    store.saveRepositoryAccessToken("github-pat")
    store.refreshDeploymentTokenAvailability()
    XCTAssertFalse(store.deploymentTokenAvailability.hasToken)
    XCTAssertFalse(store.activeDeploymentStatusReadiness.isAPIReady)

    store.saveDeploymentAccessToken("vercel-token")
    XCTAssertTrue(store.deploymentTokenAvailability.hasToken)
    XCTAssertTrue(store.activeDeploymentStatusReadiness.isAPIReady)
  }
}

private struct ConcurrentTokenCredential: Sendable {
  let name: String
  let scope: KeychainTokenScope?

  func token(round: Int) -> String {
    "\(name)-round-\(round)"
  }

  func read(from store: KeychainTokenStore, for profile: SiteProfile) throws -> String? {
    if let scope {
      return try store.token(for: profile, scope: scope)
    }
    return try store.token(for: profile)
  }

  func availability(
    in store: KeychainTokenStore,
    for profile: SiteProfile
  ) throws -> KeychainTokenAvailability {
    if let scope {
      return try store.availability(for: profile, scope: scope)
    }
    return try store.availability(for: profile)
  }

  func save(_ token: String, in store: KeychainTokenStore, for profile: SiteProfile) throws {
    if let scope {
      try store.saveToken(token, for: profile, scope: scope)
    } else {
      try store.saveToken(token, for: profile)
    }
  }

  func delete(from store: KeychainTokenStore, for profile: SiteProfile) throws {
    if let scope {
      try store.deleteToken(for: profile, scope: scope)
    } else {
      try store.deleteToken(for: profile)
    }
  }
}

private final class ConcurrentTokenFailureRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var recordedMessages: [String] = []

  var messages: [String] {
    lock.lock()
    defer { lock.unlock() }
    return recordedMessages
  }

  func record(_ message: String) {
    lock.lock()
    defer { lock.unlock() }
    if recordedMessages.count < 20 {
      recordedMessages.append(message)
    }
  }
}
