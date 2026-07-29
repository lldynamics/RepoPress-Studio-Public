import XCTest
@testable import PublishingWorkbenchCore

@MainActor
final class DistributionFeaturePolicyTests: XCTestCase {
  func testDistributionPolicyMatchesCompiledChannel() {
    XCTAssertTrue(DistributionFeaturePolicy.allowsExternalAIProviders)
    XCTAssertTrue(DistributionFeaturePolicy.allowsBrowserCapture)
    XCTAssertFalse(DistributionFeaturePolicy.visiblePremiumFeatures.contains(.aiRequest))
    XCTAssertEqual(
      DistributionFeaturePolicy.visiblePremiumFeatures,
      [.onlinePublishing, .batchPublishing]
    )
    XCTAssertTrue(ProUpgradePresentation.default.message.contains("AI"))
  }

  func testAIRequestsAreNotAdvertisedAsAProQuota() {
    XCTAssertFalse(ProUpgradePresentation.default.benefits.contains { $0.contains("AI") })
    XCTAssertTrue(DistributionFeaturePolicy.proUpgradeMessage.contains("自备"))
    let decision = MonetizationService(
      limits: FreePlanLimits(
        aiRequestLimit: 0,
        onlinePublishAttemptLimit: 0,
        batchPublishLimit: 0
      )
    ).accessDecision(for: .aiRequest, state: .default)
    XCTAssertTrue(decision.isAllowed)
    XCTAssertFalse(decision.requiresPro)
    XCTAssertNil(decision.remainingFreeUses)
  }
}
