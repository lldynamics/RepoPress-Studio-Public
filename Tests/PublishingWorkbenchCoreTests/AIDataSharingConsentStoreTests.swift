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
