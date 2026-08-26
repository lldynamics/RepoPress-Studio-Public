import PublishingWorkbenchCore
import XCTest
@testable import PersonalSitePublisherMac

final class RSSAppleTranslationRoutingTests: XCTestCase {
  private let target = RSSArticleTranslationTarget.simplifiedChinese

  func testAIBackendAlwaysUsesAIIncludingCustomTarget() {
    let custom = RSSArticleTranslationTarget.custom(language: "Português (Brasil)")!
    let decision = RSSArticleTranslationRoutingPolicy.decision(
      backend: .ai,
      force: false,
      target: custom,
      isAppleTranslationAvailable: false,
      availability: nil
    )

    XCTAssertEqual(decision, .ai)
  }

  func testAppleOnMacOS14IsBlockedWithoutAIFallback() {
    let decision = RSSArticleTranslationRoutingPolicy.decision(
      backend: .apple,
      force: true,
      target: target,
      isAppleTranslationAvailable: false,
      availability: .installed
    )

    XCTAssertEqual(decision, .blocked(.requiresMacOS15))
  }

  func testAutomaticInstalledPairUsesApple() {
    let decision = RSSArticleTranslationRoutingPolicy.decision(
      backend: .apple,
      force: false,
      target: target,
      isAppleTranslationAvailable: true,
      availability: .installed
    )

    XCTAssertEqual(decision, .apple)
  }

  func testAutomaticSupportedPairOnlyReportsDownloadRequirement() {
    let decision = RSSArticleTranslationRoutingPolicy.decision(
      backend: .apple,
      force: false,
      target: target,
      isAppleTranslationAvailable: true,
      availability: .supported
    )

    XCTAssertEqual(decision, .blocked(.languageDownloadRequired))
  }

  func testManualSupportedPairMayAskSystemToDownload() {
    let decision = RSSArticleTranslationRoutingPolicy.decision(
      backend: .apple,
      force: true,
      target: target,
      isAppleTranslationAvailable: true,
      availability: .supported
    )

    XCTAssertEqual(decision, .apple)
  }

  func testUnsupportedPairIsReportedForAutomaticAndManualRequests() {
    let automatic = RSSArticleTranslationRoutingPolicy.decision(
      backend: .apple,
      force: false,
      target: target,
      isAppleTranslationAvailable: true,
      availability: .unsupported
    )
    let manual = RSSArticleTranslationRoutingPolicy.decision(
      backend: .apple,
      force: true,
      target: target,
      isAppleTranslationAvailable: true,
      availability: .unsupported
    )

    XCTAssertEqual(automatic, .blocked(.unsupportedLanguagePair))
    XCTAssertEqual(manual, .blocked(.unsupportedLanguagePair))
  }

  func testAppleCustomTargetIsBlockedBeforeAvailability() {
    let custom = RSSArticleTranslationTarget.custom(language: "Português (Brasil)")!
    let decision = RSSArticleTranslationRoutingPolicy.decision(
      backend: .apple,
      force: true,
      target: custom,
      isAppleTranslationAvailable: true,
      availability: .installed
    )

    XCTAssertEqual(decision, .blocked(.customTarget))
  }

  func testMissingAvailabilityDoesNotPermitAutomaticAppleRequest() {
    let decision = RSSArticleTranslationRoutingPolicy.decision(
      backend: .apple,
      force: false,
      target: target,
      isAppleTranslationAvailable: true,
      availability: nil
    )

    XCTAssertEqual(decision, .blocked(.availabilityUnknown))
  }

  func testTranslationCacheKeySeparatesAppleAndAIResults() {
    let fetchedAt = Date(timeIntervalSinceReferenceDate: 42)
    let appleKey = RSSArticleTranslationCacheKey(
      articleID: "article-1",
      fetchedAt: fetchedAt,
      targetCode: target.languageCode,
      backend: .apple
    )
    let aiKey = RSSArticleTranslationCacheKey(
      articleID: "article-1",
      fetchedAt: fetchedAt,
      targetCode: target.languageCode,
      backend: .ai
    )

    XCTAssertNotEqual(appleKey, aiKey)
  }
}
