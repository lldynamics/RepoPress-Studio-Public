import Foundation
import PublishingCoreSupport
import XCTest

@testable import PersonalSitePublisherMac
@testable import PublishingAICore

final class AIConnectionSetupPresentationTests: XCTestCase {

  func testResolvedModelAliasDoesNotInvalidateSuccessfulRequest() {
    let report = AIConnectionTestReport(
      providerName: "测试", model: "model-resolved-version",
      endpoint: URL(string: "https://api.example.com/v1/chat/completions")!,
      responsePreview: "ok", requestedModel: "model")
    let presentation = AIConnectionSetupPresentation.make(
      config: configured(), tokenAvailability: .init(hasToken: true),
      dataSharingConsent: consent(granted: true), report: report, isTesting: false)
    XCTAssertEqual(presentation.nextStep, .success)
  }

  func testEmptyModelStillGuidesUserThroughCredentialsAndConsentFirst() {
    let config = AIProviderConfig(
      preset: .openRouter, baseURL: AIProviderPreset.openRouter.defaultBaseURL, model: "")
    let withoutKey = AIConnectionSetupPresentation.make(
      config: config, tokenAvailability: .init(hasToken: false),
      dataSharingConsent: consent(granted: false), report: nil, isTesting: false)
    XCTAssertEqual(withoutKey.nextStep, .missingAPIKey)
    let withoutConsent = AIConnectionSetupPresentation.make(
      config: config, tokenAvailability: .init(hasToken: true),
      dataSharingConsent: consent(granted: false), report: nil, isTesting: false)
    XCTAssertEqual(withoutConsent.nextStep, .consentRequired)
  }

  func testStaleReportCannotMarkDifferentModelOrRevokedConsentReady() {
    let report = AIConnectionTestReport(
      providerName: "测试", model: "old-model",
      endpoint: URL(string: "https://api.example.com/v1/chat/completions")!, responsePreview: "ok")
    let changed = AIConnectionSetupPresentation.make(
      config: configured(), tokenAvailability: .init(hasToken: true),
      dataSharingConsent: consent(granted: true), report: report, isTesting: false)
    XCTAssertNotEqual(changed.nextStep, .success)
    let revoked = AIConnectionSetupPresentation.make(
      config: configured(), tokenAvailability: .init(hasToken: true),
      dataSharingConsent: consent(granted: false), report: report, isTesting: false)
    XCTAssertEqual(revoked.nextStep, .consentRequired)
  }
  func testMissingAddressAndModelAreReportedBeforeCredentials() {
    let consent = consent(granted: true)
    let missingAddress = AIConnectionSetupPresentation.make(
      config: AIProviderConfig(preset: .custom, model: "model"),
      tokenAvailability: KeychainTokenAvailability(hasToken: false),
      dataSharingConsent: consent,
      report: nil,
      isTesting: false
    )
    XCTAssertEqual(missingAddress.nextStep, .missingBaseURL)

    let missingModel = AIConnectionSetupPresentation.make(
      config: AIProviderConfig(preset: .custom, baseURL: "https://api.example.com/v1"),
      tokenAvailability: KeychainTokenAvailability(hasToken: true),
      dataSharingConsent: consent,
      report: nil,
      isTesting: false
    )
    XCTAssertEqual(missingModel.nextStep, .missingModel)
  }

  func testCredentialAndAuthorizationStatesAreActionable() {
    let config = configured()
    let missingKey = AIConnectionSetupPresentation.make(
      config: config,
      tokenAvailability: KeychainTokenAvailability(hasToken: false),
      dataSharingConsent: consent(granted: true),
      report: nil,
      isTesting: false
    )
    XCTAssertEqual(missingKey.nextStep, .missingAPIKey)

    let failedKey = AIConnectionSetupPresentation.make(
      config: config,
      tokenAvailability: KeychainTokenAvailability(hasToken: false, accessFailureMessage: "拒绝访问"),
      dataSharingConsent: consent(granted: true),
      report: nil,
      isTesting: false
    )
    XCTAssertEqual(failedKey.nextStep, .credentialAccessFailed)

    let unauthorized = AIConnectionSetupPresentation.make(
      config: config,
      tokenAvailability: KeychainTokenAvailability(hasToken: true),
      dataSharingConsent: consent(granted: false),
      report: nil,
      isTesting: false
    )
    XCTAssertEqual(unauthorized.nextStep, .consentRequired)

    let reauthorization = AIConnectionSetupPresentation.make(
      config: config,
      tokenAvailability: KeychainTokenAvailability(hasToken: true),
      dataSharingConsent: AIDataSharingConsentPresentation(
        providerName: "测试服务",
        destination: "api.example.com",
        destinationState: .remote,
        isGranted: true,
        requiresAccountReauthorization: true
      ),
      report: nil,
      isTesting: false
    )
    XCTAssertEqual(reauthorization.nextStep, .consentRequired)
  }

  func testTestingAndSuccessfulReportStatesTakePrecedence() {
    let config = configured()
    let testing = AIConnectionSetupPresentation.make(
      config: config,
      tokenAvailability: KeychainTokenAvailability(hasToken: true),
      dataSharingConsent: consent(granted: true),
      report: nil,
      isTesting: true
    )
    XCTAssertEqual(testing.nextStep, .testing)

    let report = AIConnectionTestReport(
      providerName: "测试服务",
      model: "model",
      endpoint: URL(string: "https://api.example.com/v1/chat/completions")!,
      responsePreview: "ok"
    )
    let success = AIConnectionSetupPresentation.make(
      config: config,
      tokenAvailability: KeychainTokenAvailability(hasToken: true),
      dataSharingConsent: consent(granted: true),
      report: report,
      isTesting: false
    )
    XCTAssertEqual(success.nextStep, .success)
    XCTAssertTrue(success.title.contains("连接正常"))
  }

  func testChangedPresetGatewayHasNoOfficialPresetGuide() {
    let config = AIProviderConfig(
      preset: .deepSeek,
      baseURL: "https://gateway.example.com/v1",
      model: "deepseek-v4-flash"
    )
    let presentation = AIConnectionSetupPresentation.make(
      config: config,
      tokenAvailability: KeychainTokenAvailability(hasToken: true),
      dataSharingConsent: consent(granted: true),
      report: nil,
      isTesting: false
    )
    XCTAssertEqual(presentation.nextStep, .changedGateway)
    XCTAssertNil(presentation.guide)
  }

  private func configured() -> AIProviderConfig {
    AIProviderConfig(
      preset: .custom,
      baseURL: "https://api.example.com/v1",
      model: "model",
      requiresAPIKey: true
    )
  }

  private func consent(granted: Bool) -> AIDataSharingConsentPresentation {
    AIDataSharingConsentPresentation(
      providerName: "测试服务",
      destination: "api.example.com",
      destinationState: .remote,
      isGranted: granted
    )
  }
}
