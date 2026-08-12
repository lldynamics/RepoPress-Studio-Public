import XCTest

@testable import PersonalSitePublisherMac
@testable import PublishingWorkbenchCore

final class AISettingsFlowPresentationTests: XCTestCase {
  func testStructuredDestinationsSelectTheExpectedAISection() {
    XCTAssertEqual(AISettingsSection(destination: .connection), .connection)
    XCTAssertEqual(AISettingsSection(destination: .credentials), .credentials)
    XCTAssertEqual(AISettingsSection(destination: .writingStyle), .writingStyle)
  }

  func testAISectionsUseTaskOrientedTitles() {
    XCTAssertEqual(
      AISettingsSection.allCases.map(\.title),
      ["连接与服务", "凭据授权与测试", "写作风格"]
    )
  }

  func testAdvancedConnectionSettingsStartCollapsed() {
    let state = AISettingsExpansionState()

    XCTAssertFalse(state.advancedConnection)
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

  func testAutomaticInlineAICompletionDefaultsOff() {
    XCTAssertFalse(AIWritingPreferences.defaultAutomaticInlineCompletionEnabled)
  }
}
