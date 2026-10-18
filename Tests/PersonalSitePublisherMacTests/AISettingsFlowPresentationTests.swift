import PublishingCoreSupport
import SwiftUI
import XCTest

@testable import PersonalSitePublisherMac
@testable import PublishingAICore

final class AISettingsFlowPresentationTests: XCTestCase {
  func testOfficialProvidersHideConnectionFieldsWhileCustomAndChangedGatewaysShowThem() {
    for preset in AIProviderPreset.allCases where preset != .codexAppServer {
      var config = AIProviderConfig(preset: preset)
      config.applyPresetDefaults()
      XCTAssertEqual(
        AIProviderFieldPresentation(config: config).showsConnectionFieldsByDefault,
        preset == .custom || preset == .local,
        "Unexpected default field visibility for \(preset)")
      config.baseURL = "https://gateway.example.com/v1"
      XCTAssertTrue(AIProviderFieldPresentation(config: config).showsConnectionFieldsByDefault)
    }
  }

  func testNondefaultCredentialRequirementRemainsVisibleForOfficialEndpoint() {
    var config = AIProviderConfig(preset: .deepSeek)
    config.applyPresetDefaults()
    config.requiresAPIKey = false
    XCTAssertTrue(AIProviderFieldPresentation(config: config).showsConnectionFieldsByDefault)
  }

  @MainActor
  func testFailedKeySavePreservesInputAndDoesNotContinue() {
    var input = "test-key-kept-on-failure"
    var continuations = 0
    let didSave = AIAPIKeySaveAction.perform(
      input: Binding(get: { input }, set: { input = $0 }), save: { false },
      continueSetup: { continuations += 1 })
    XCTAssertFalse(didSave)
    XCTAssertEqual(input, "test-key-kept-on-failure")
    XCTAssertEqual(continuations, 0)
  }

  @MainActor
  func testKeySaveConsumesInputOnlyOnSuccessAndContinuationIsExplicit() {
    var input = "  'test-key'  "
    var savedValues: [String] = []
    var continuations = 0
    let binding = Binding(get: { input }, set: { input = $0 })
    XCTAssertTrue(
      AIAPIKeySaveAction.perform(
        input: binding,
        save: {
          savedValues.append(input)
          return true
        },
        continueSetup: { continuations += 1 }))
    XCTAssertEqual(savedValues, ["test-key"])
    XCTAssertEqual(input, "")
    XCTAssertEqual(continuations, 1)
    input = "test-key-two"
    XCTAssertTrue(
      AIAPIKeySaveAction.perform(
        input: binding,
        save: {
          savedValues.append(input)
          return true
        }, continueSetup: nil))
    XCTAssertEqual(continuations, 1)
    XCTAssertEqual(input, "")
  }

  func testProviderPresetsCollapseIntoThreeUserFacingConnectionKinds() {
    XCTAssertEqual(AIConnectionKind(preset: .codexAppServer), .chatGPT)
    XCTAssertEqual(AIConnectionKind(preset: .local), .local)
    XCTAssertEqual(AIConnectionKind(preset: .openAICompatible), .apiKey)
    XCTAssertEqual(AIConnectionKind(preset: .deepSeek), .apiKey)
    XCTAssertEqual(AIConnectionKind(preset: .openRouter), .apiKey)
    XCTAssertEqual(AIConnectionKind(preset: .custom), .apiKey)
  }

  func testWritingStyleDestinationUsesTheMergedAISubsection() {
    XCTAssertEqual(
      SettingsSubsection.section(for: .ai(.writingStyle)),
      .aiWritingStyle
    )
    XCTAssertEqual(SettingsSubsection.aiWritingStyle.tab, .ai)
    XCTAssertEqual(SettingsSubsection.aiSiteConnection.tab, .ai)
    XCTAssertEqual(SettingsSubsection.aiConnection.tab, .ai)
  }

  func testConnectionTestRequiresEndpointThenKeyThenConsent() {
    let consentRequired = AIDataSharingConsentPresentation(
      providerName: "Remote AI",
      destination: "api.example.com",
      destinationState: .remote,
      isGranted: false
    )
    let missingEndpoint = AIProviderConfig(
      preset: .custom,
      baseURL: "",
      model: "example-model",
      requiresAPIKey: true
    )
    let configured = AIProviderConfig(
      preset: .custom,
      baseURL: "https://api.example.com/v1",
      model: "example-model",
      requiresAPIKey: true
    )

    XCTAssertEqual(
      AIConnectionTestAvailability(
        config: missingEndpoint,
        tokenAvailability: KeychainTokenAvailability(hasToken: false),
        dataSharingConsent: consentRequired
      ),
      .missingBaseURL
    )
    XCTAssertEqual(
      AIConnectionTestAvailability(
        config: configured,
        tokenAvailability: KeychainTokenAvailability(hasToken: false),
        dataSharingConsent: consentRequired
      ),
      .missingAPIKey
    )
    XCTAssertEqual(
      AIConnectionTestAvailability(
        config: configured,
        tokenAvailability: KeychainTokenAvailability(hasToken: true),
        dataSharingConsent: consentRequired
      ),
      .consentRequired
    )

    let consentGranted = AIDataSharingConsentPresentation(
      providerName: "Remote AI",
      destination: "api.example.com",
      destinationState: .remote,
      isGranted: true
    )
    let ready = AIConnectionTestAvailability(
      config: configured,
      tokenAvailability: KeychainTokenAvailability(hasToken: true),
      dataSharingConsent: consentGranted
    )
    XCTAssertEqual(ready, .ready)
    XCTAssertTrue(ready.isEnabled)
  }

  func testLocalConnectionCanBeTestedWithoutAPIKeyOrRemoteConsent() {
    let localConfig = AIProviderConfig(
      preset: .local,
      baseURL: "http://127.0.0.1:11434/v1",
      model: "qwen2.5",
      requiresAPIKey: false
    )
    let localConsent = AIDataSharingConsentPresentation(
      providerName: "Local",
      destination: "127.0.0.1:11434",
      destinationState: .local,
      isGranted: true
    )

    XCTAssertEqual(
      AIConnectionTestAvailability(
        config: localConfig,
        tokenAvailability: KeychainTokenAvailability(hasToken: false),
        dataSharingConsent: localConsent
      ),
      .ready
    )
  }

  func testInvalidURLAndHTTPAPIKeyBlockConnectionTestingBeforeAnyRequest() {
    let consent = AIDataSharingConsentPresentation(
      providerName: "Remote AI",
      destination: "api.example.com",
      destinationState: .remote,
      isGranted: true
    )
    let malformed = AIProviderConfig(
      preset: .custom,
      baseURL: "not a valid URL",
      model: "model",
      requiresAPIKey: false
    )
    let credentialedHTTP = AIProviderConfig(
      preset: .custom,
      baseURL: "http://127.0.0.1:11434/v1",
      model: "model",
      requiresAPIKey: true
    )

    XCTAssertEqual(
      AIConnectionTestAvailability(
        config: malformed,
        tokenAvailability: KeychainTokenAvailability(hasToken: false),
        dataSharingConsent: consent
      ),
      .invalidEndpoint(.invalidURL)
    )
    XCTAssertEqual(
      AIConnectionTestAvailability(
        config: credentialedHTTP,
        tokenAvailability: KeychainTokenAvailability(hasToken: true),
        dataSharingConsent: consent
      ),
      .invalidEndpoint(.insecureCredentialURL)
    )
  }

  func testCodexConnectionNeedsRemoteConsentButNoAPIKey() {
    var config = AIProviderConfig(preset: .codexAppServer)
    config.applyPresetDefaults()
    let consentRequired = AIDataSharingConsentPresentation(
      providerName: "Codex",
      destination: "Codex / ChatGPT",
      destinationState: .remote,
      isGranted: false
    )

    XCTAssertEqual(
      AIConnectionTestAvailability(
        config: config,
        tokenAvailability: KeychainTokenAvailability(hasToken: false),
        dataSharingConsent: consentRequired
      ),
      .consentRequired
    )

    let granted = AIDataSharingConsentPresentation(
      providerName: "Codex",
      destination: "Codex / ChatGPT",
      destinationState: .remote,
      isGranted: true
    )
    XCTAssertEqual(
      AIConnectionTestAvailability(
        config: config,
        tokenAvailability: KeychainTokenAvailability(hasToken: false),
        dataSharingConsent: granted
      ),
      .ready
    )
  }

  func testFirstSendConfirmationOnlyAppearsForUngrantedRemoteDestination() {
    XCTAssertTrue(
      AIChatDataSharingConsentPolicy.requiresConfirmation(
        AIDataSharingConsentPresentation(
          providerName: "ChatGPT",
          destination: "Codex / ChatGPT",
          destinationState: .remote,
          isGranted: false
        )
      )
    )
    XCTAssertFalse(
      AIChatDataSharingConsentPolicy.requiresConfirmation(
        AIDataSharingConsentPresentation(
          providerName: "ChatGPT",
          destination: "Codex / ChatGPT",
          destinationState: .remote,
          isGranted: true
        )
      )
    )
    XCTAssertFalse(
      AIChatDataSharingConsentPolicy.requiresConfirmation(
        AIDataSharingConsentPresentation(
          providerName: "Local",
          destination: "127.0.0.1:11434",
          destinationState: .local,
          isGranted: true
        )
      )
    )
  }

  func testCodexConsentRedirectsToLiveAccountSettingsInsteadOfStatuslessGrant() {
    var codexConfig = AIProviderConfig(preset: .codexAppServer)
    codexConfig.applyPresetDefaults()
    let codexConsent = AIDataSharingConsentPresentation(
      providerName: "ChatGPT",
      destination: "Codex / ChatGPT",
      destinationState: .remote,
      isGranted: false
    )
    XCTAssertTrue(
      AIChatDataSharingConsentPolicy.requiresAccountSettingsRedirect(
        for: codexConfig,
        presentation: codexConsent
      )
    )

    let apiConfig = AIProviderConfig(
      preset: .custom,
      baseURL: "https://api.example.com/v1",
      model: "example-model",
      requiresAPIKey: true
    )
    XCTAssertFalse(
      AIChatDataSharingConsentPolicy.requiresAccountSettingsRedirect(
        for: apiConfig,
        presentation: codexConsent
      )
    )
  }

  func testKeychainFeedbackKeepsCredentialFailuresVisibleWithoutEchoingConnectionTests() {
    let failure = AIKeychainActionFeedback(message: "AI API Key 保存失败：访问被拒绝")
    XCTAssertEqual(failure?.message, "AI API Key 保存失败：访问被拒绝")
    XCTAssertEqual(failure?.isError, true)
    XCTAssertEqual(
      AIKeychainActionFeedback(message: "AI API Key 已保存到本地配置文件。")?.isError,
      false
    )
    XCTAssertNil(AIKeychainActionFeedback(message: "AI 连接测试失败：网络不可用"))
  }

  @MainActor
  func testAPIKeyConfigurationNavigationTargetsConnectionSection() {
    XCTAssertEqual(
      SettingsView.settingsDestination(for: .aiKey),
      .ai(.connection)
    )
  }

  @MainActor
  func testOnlyAPIKeyConnectionsNeedCredentialNavigation() {
    let codexConfig = AIProviderConfig(preset: .codexAppServer)
    let apiConfig = AIProviderConfig(
      preset: .custom,
      baseURL: "https://api.example.com/v1",
      model: "example-model",
      requiresAPIKey: true
    )

    XCTAssertFalse(
      SettingsView.shouldOpenAIKeyConnection(
        for: codexConfig,
        tokenAvailability: KeychainTokenAvailability(hasToken: false)
      )
    )
    XCTAssertTrue(
      SettingsView.shouldOpenAIKeyConnection(
        for: apiConfig,
        tokenAvailability: KeychainTokenAvailability(hasToken: false)
      )
    )
  }
}
