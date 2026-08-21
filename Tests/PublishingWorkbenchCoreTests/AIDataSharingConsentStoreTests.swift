import XCTest

@testable import PublishingWorkbenchCore

final class AIDataSharingConsentStoreTests: XCTestCase {
  private var suiteName: String!
  private var defaults: UserDefaults!

  override func setUp() {
    super.setUp()
    suiteName = "AIDataSharingConsentStoreTests.\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)
  }

  override func tearDown() {
    defaults.removePersistentDomain(forName: suiteName)
    defaults = nil
    suiteName = nil
    super.tearDown()
  }

  func testRemoteProviderRequiresExplicitConsentAndCanBeRevoked() {
    let store = AIDataSharingConsentStore(defaults: defaults)
    let config = AIProviderConfig(
      preset: .custom,
      baseURL: "https://api.custom-ai.com/v1",
      model: "custom-model",
      requiresAPIKey: true
    )

    XCTAssertEqual(config.dataSharingDestination, "api.custom-ai.com")
    XCTAssertFalse(store.presentation(for: config).isGranted)

    store.grant(for: config)
    XCTAssertTrue(store.presentation(for: config).isGranted)

    store.revoke(for: config)
    XCTAssertFalse(store.presentation(for: config).isGranted)
  }

  func testFreshInstallWithoutGrantStartsWithRemoteMasterDisabled() {
    let store = AIDataSharingConsentStore(defaults: defaults)
    let config = AIProviderConfig(
      preset: .custom,
      baseURL: "https://api.custom-ai.com/v1",
      model: "custom-model",
      requiresAPIKey: true
    )

    XCTAssertFalse(store.isRemoteAIEnabled)
    let presentation = store.presentation(for: config)
    XCTAssertFalse(presentation.isGranted)
    XCTAssertFalse(presentation.hasDestinationGrant)
    XCTAssertFalse(presentation.isRemoteAIEnabled)
  }

  func testExistingDestinationGrantMakesMissingRemoteMasterKeyEnabled() {
    let store = AIDataSharingConsentStore(defaults: defaults)
    let config = AIProviderConfig(
      preset: .custom,
      baseURL: "https://api.custom-ai.com/v1",
      model: "custom-model",
      requiresAPIKey: true
    )
    defaults.set(
      [config.dataSharingConsentIdentifier], forKey: AIDataSharingConsentStore.defaultStorageKey)

    XCTAssertTrue(store.isRemoteAIEnabled)
    XCTAssertTrue(store.presentation(for: config).isGranted)
  }

  func testRevokingLastLegacyGrantDoesNotDisableRemoteMasterSwitch() {
    let store = AIDataSharingConsentStore(defaults: defaults)
    let config = AIProviderConfig(
      preset: .custom,
      baseURL: "https://api.custom-ai.com/v1",
      model: "custom-model",
      requiresAPIKey: true
    )
    defaults.set(
      [config.dataSharingConsentIdentifier],
      forKey: AIDataSharingConsentStore.defaultStorageKey
    )
    XCTAssertTrue(store.isRemoteAIEnabled)

    store.revoke(for: config)

    XCTAssertTrue(store.isRemoteAIEnabled)
    XCTAssertFalse(store.presentation(for: config).isGranted)
  }

  func testRemoteMasterOffBlocksTransportEligibilityButPreservesGrantAndRestoresIt() {
    let store = AIDataSharingConsentStore(defaults: defaults)
    let remote = AIProviderConfig(
      preset: .custom,
      baseURL: "https://api.custom-ai.com/v1",
      model: "custom-model",
      requiresAPIKey: true
    )
    let local = AIProviderConfig(
      preset: .local,
      baseURL: "http://127.0.0.1:11434/v1",
      model: "llama3.1",
      requiresAPIKey: false
    )
    XCTAssertTrue(store.grant(for: remote))
    XCTAssertTrue(store.presentation(for: remote).isGranted)

    store.setRemoteAIEnabled(false)
    let disabledRemotePresentation = store.presentation(for: remote)
    XCTAssertFalse(disabledRemotePresentation.isGranted)
    XCTAssertFalse(disabledRemotePresentation.isRemoteAIEnabled)
    XCTAssertTrue(disabledRemotePresentation.hasDestinationGrant)
    XCTAssertTrue(store.presentation(for: local).isGranted)

    store.setRemoteAIEnabled(true)
    XCTAssertTrue(store.presentation(for: remote).isGranted)
  }

  func testRemoteMasterOffWithoutDestinationGrantHasNoRetainedGrant() {
    let store = AIDataSharingConsentStore(defaults: defaults)
    let remote = AIProviderConfig(
      preset: .custom,
      baseURL: "https://api.custom-ai.com/v1",
      model: "custom-model",
      requiresAPIKey: true
    )

    store.setRemoteAIEnabled(false)

    let presentation = store.presentation(for: remote)
    XCTAssertFalse(presentation.isGranted)
    XCTAssertFalse(presentation.hasDestinationGrant)
    XCTAssertFalse(presentation.isRemoteAIEnabled)
  }

  func testDestinationGrantCannotReenableExplicitlyDisabledRemoteMaster() {
    let store = AIDataSharingConsentStore(defaults: defaults)
    let config = AIProviderConfig(
      preset: .custom,
      baseURL: "https://api.custom-ai.com/v1",
      model: "custom-model",
      requiresAPIKey: true
    )
    store.setRemoteAIEnabled(false)
    XCTAssertTrue(store.grant(for: config))
    XCTAssertFalse(store.presentation(for: config).isGranted)
    store.setRemoteAIEnabled(true)
    XCTAssertTrue(store.presentation(for: config).isGranted)
  }

  func testConsentDoesNotCarryAcrossRemoteDestinations() {
    let store = AIDataSharingConsentStore(defaults: defaults)
    let customAI = AIProviderConfig(
      preset: .custom,
      baseURL: "https://api.custom-ai.com/v1",
      model: "custom-model",
      requiresAPIKey: true
    )
    let openAI = AIProviderConfig(
      preset: .custom,
      baseURL: "https://api.openai.com/v1",
      model: "gpt-4.1-mini",
      requiresAPIKey: true
    )

    store.grant(for: customAI)

    XCTAssertTrue(store.presentation(for: customAI).isGranted)
    XCTAssertFalse(store.presentation(for: openAI).isGranted)
  }

  func testLoopbackProviderDoesNotRequireThirdPartyConsent() {
    let store = AIDataSharingConsentStore(defaults: defaults)
    let config = AIProviderConfig(
      preset: .local,
      baseURL: "http://127.0.0.1:11434/v1",
      model: "llama3.1",
      requiresAPIKey: false
    )

    let presentation = store.presentation(for: config)
    XCTAssertEqual(presentation.destinationState, .local)
    XCTAssertFalse(presentation.requiresConsent)
    XCTAssertTrue(presentation.isGranted)
  }

  func testCodexAppServerStillRequiresRemoteDataConsent() {
    let store = AIDataSharingConsentStore(defaults: defaults)
    var config = AIProviderConfig(preset: .codexAppServer)
    config.applyPresetDefaults()

    let presentation = store.presentation(for: config)

    XCTAssertEqual(presentation.destination, "Codex / ChatGPT")
    XCTAssertEqual(presentation.destinationState, .remote)
    XCTAssertTrue(presentation.requiresConsent)
    XCTAssertFalse(presentation.isGranted)
  }

  func testLegacyCodexGrantFailsClosedUntilAccountIsExplicitlyReauthorized() {
    let store = AIDataSharingConsentStore(defaults: defaults)
    var config = AIProviderConfig(preset: .codexAppServer)
    config.applyPresetDefaults()
    defaults.set(
      [config.dataSharingConsentIdentifier],
      forKey: AIDataSharingConsentStore.defaultStorageKey
    )
    let account = CodexAppServerAccountStatus(
      isAuthenticated: true,
      accountID: "acct-legacy-test",
      accountType: "chatgpt",
      email: "legacy@example.com"
    )

    XCTAssertFalse(store.presentation(for: config).isGranted)
    let presentation = store.presentation(for: config, codexAccountStatus: account)
    XCTAssertFalse(presentation.isGranted)
    XCTAssertTrue(presentation.requiresAccountReauthorization)
    XCTAssertFalse(store.isCodexAccountAuthorized(for: config, accountStatus: account))
  }

  func testCodexGrantBindsDigestToSameAccountAndRejectsChangedOrMissingIdentity() {
    let store = AIDataSharingConsentStore(defaults: defaults)
    var config = AIProviderConfig(preset: .codexAppServer)
    config.applyPresetDefaults()
    let account = CodexAppServerAccountStatus(
      isAuthenticated: true,
      accountID: "acct-bound-test",
      accountType: "chatgpt",
      email: "bound@example.com"
    )

    XCTAssertTrue(store.grant(for: config, codexAccountStatus: account))
    // Synchronous destination checks may pass a stored binding through to the
    // request helper; the live authorizer still revalidates the account below.
    XCTAssertTrue(store.presentation(for: config).isGranted)
    XCTAssertTrue(store.isCodexAccountAuthorized(for: config, accountStatus: account))
    XCTAssertTrue(
      store.presentation(for: config, codexAccountStatus: account).isGranted
    )

    let digest = try! XCTUnwrap(store.codexAccountBindingDigest)
    XCTAssertFalse(digest.contains("acct-bound-test"))
    XCTAssertFalse(digest.contains("bound@example.com"))
    let persisted = defaults.dictionaryRepresentation().values
      .compactMap { $0 as? String }
      .joined(separator: "|")
    XCTAssertFalse(persisted.contains("acct-bound-test"))
    XCTAssertFalse(persisted.contains("bound@example.com"))

    let changedAccount = CodexAppServerAccountStatus(
      isAuthenticated: true,
      accountID: "acct-other-test",
      accountType: "chatgpt",
      email: "bound@example.com"
    )
    XCTAssertFalse(store.isCodexAccountAuthorized(for: config, accountStatus: changedAccount))
    XCTAssertFalse(
      store.presentation(for: config, codexAccountStatus: changedAccount).isGranted
    )

    let loggedOut = CodexAppServerAccountStatus(
      isAuthenticated: false,
      accountID: "acct-bound-test",
      accountType: "chatgpt",
      email: "bound@example.com"
    )
    XCTAssertFalse(store.isCodexAccountAuthorized(for: config, accountStatus: loggedOut))

    let missingIdentity = CodexAppServerAccountStatus(
      isAuthenticated: true,
      accountType: "chatgpt"
    )
    XCTAssertFalse(store.isCodexAccountAuthorized(for: config, accountStatus: missingIdentity))
  }

  func testCodexEmailFallbackIsNormalizedButAccountIDRemainsPreferred() {
    let store = AIDataSharingConsentStore(defaults: defaults)
    var config = AIProviderConfig(preset: .codexAppServer)
    config.applyPresetDefaults()
    let emailAccount = CodexAppServerAccountStatus(
      isAuthenticated: true,
      email: "  User@Example.COM "
    )

    XCTAssertTrue(store.grant(for: config, codexAccountStatus: emailAccount))
    let normalizedEmailAccount = CodexAppServerAccountStatus(
      isAuthenticated: true,
      email: "user@example.com"
    )
    XCTAssertTrue(
      store.isCodexAccountAuthorized(for: config, accountStatus: normalizedEmailAccount)
    )

    let accountIDTakesPriority = CodexAppServerAccountStatus(
      isAuthenticated: true,
      accountID: "acct-new-stable-id",
      email: "user@example.com"
    )
    XCTAssertFalse(
      store.isCodexAccountAuthorized(for: config, accountStatus: accountIDTakesPriority)
    )
  }

  func testEmptyDestinationIsUnconfiguredInsteadOfLocalOrGranted() {
    let store = AIDataSharingConsentStore(defaults: defaults)
    let config = AIProviderConfig(
      preset: .custom,
      baseURL: "",
      model: "",
      requiresAPIKey: true
    )

    let presentation = store.presentation(for: config)

    XCTAssertEqual(presentation.destination, "")
    XCTAssertEqual(presentation.destinationState, .unconfigured)
    XCTAssertFalse(presentation.requiresConsent)
    XCTAssertFalse(presentation.isGranted)
    XCTAssertFalse(store.grant(for: config))
  }
}
