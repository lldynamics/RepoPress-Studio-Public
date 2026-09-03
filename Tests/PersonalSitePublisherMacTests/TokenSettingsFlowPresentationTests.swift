import PublishingWorkbenchCore
import XCTest

@testable import PersonalSitePublisherMac

final class TokenSettingsFlowPresentationTests: XCTestCase {
  func testStructuredTokenDestinationsSelectTheirExactScope() {
    XCTAssertEqual(TokenSettingsScope(destination: .repository), .repository)
    XCTAssertEqual(TokenSettingsScope(destination: .deployment), .deployment)
    XCTAssertEqual(TokenSettingsScope(destination: .analytics), .analytics)
  }

  func testProfileChangeCanClearEveryUnsavedCredentialDraft() {
    var drafts = TokenCredentialDrafts(
      repository: "repository-secret",
      deployment: "deployment-secret",
      analytics: "analytics-secret"
    )

    XCTAssertNotEqual(drafts, TokenCredentialDrafts())

    drafts.clearAll()

    XCTAssertEqual(drafts, TokenCredentialDrafts())
  }

  func testRepositorySummaryDistinguishesFilledValuesFromVerifiedAccess() {
    let profile = SiteProfile(
      name: "Personal Site",
      localRepositoryRootPath: "/tmp/site",
      repoOwner: "octocat",
      repoName: "site",
      branch: "main"
    )

    let presentation = TokenConnectionStatusPresentation.repository(
      profile: profile,
      tokenAvailability: KeychainTokenAvailability(hasToken: true)
    )

    XCTAssertEqual(presentation.title, "仓库目标已填写")
    XCTAssertEqual(presentation.tone, .neutral)
    XCTAssertTrue(presentation.detail.contains("运行权限检查"))
    XCTAssertFalse(presentation.detail.contains("已验证"))
  }

  func testDeploymentSummaryReportsReadinessWithoutInventingAnOnlineTest() {
    let readiness = DeploymentStatusProviderReadiness(
      provider: .netlify,
      isAPIReady: false,
      canCheckAnyStatus: true,
      configuredSignals: ["站点 URL"],
      missingRequirements: ["Site ID"],
      fallbackMessage: "可检查站点 URL",
      nextStep: "填写 Site ID"
    )

    let presentation = TokenConnectionStatusPresentation.deployment(
      readiness: readiness,
      tokenAvailability: KeychainTokenAvailability(hasToken: false)
    )

    XCTAssertEqual(presentation.tone, .warning)
    XCTAssertTrue(presentation.detail.contains("填写 Site ID"))
    XCTAssertFalse(presentation.detail.contains("在线测试通过"))
  }
}
