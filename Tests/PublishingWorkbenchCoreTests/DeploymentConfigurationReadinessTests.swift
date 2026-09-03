import XCTest

@testable import PublishingWorkbenchCore

final class DeploymentConfigurationReadinessTests: XCTestCase {
  func testPublishingProfileRequiresExplicitPlatformAndProductionURL() {
    let profile = SiteProfile.defaultProfile

    let readiness = DeploymentConfigurationReadiness(profile: profile)
    let statusReadiness = DeploymentStatusService().readiness(profile: profile, hasToken: false)

    XCTAssertTrue(readiness.requiresProductionVerification)
    XCTAssertFalse(readiness.hasExplicitProvider)
    XCTAssertFalse(readiness.hasExplicitSiteURL)
    XCTAssertTrue(readiness.needsExplicitProviderConfirmation)
    XCTAssertTrue(readiness.issues.contains { $0.contains("未明确选择部署平台") })
    XCTAssertTrue(readiness.issues.contains { $0.contains("未填写生产站点 URL") })
    XCTAssertEqual(statusReadiness.provider, .githubPages)
    XCTAssertTrue(statusReadiness.needsExplicitProviderConfirmation)
    XCTAssertEqual(statusReadiness.productionVerificationIssues, readiness.issues)
    XCTAssertNil(profile.deploymentProvider)
    XCTAssertNil(profile.deploymentSiteURL)
  }

  func testCloudflareRequiresAccountProjectAndProductionURLWithoutChangingAPIReadiness() {
    var profile = SiteProfile.defaultProfile
    profile.deploymentProvider = .cloudflarePages
    profile.deploymentAccountID = "account-123"
    profile.deploymentProjectID = "personal-site"

    let readiness = DeploymentStatusService().readiness(profile: profile, hasToken: true)

    XCTAssertTrue(readiness.isAPIReady)
    XCTAssertTrue(readiness.missingRequirements.isEmpty)
    XCTAssertFalse(readiness.needsExplicitProviderConfirmation)
    XCTAssertTrue(
      readiness.productionVerificationIssues.contains {
        $0.contains("未填写生产站点 URL")
      })
  }

  func testCloudflareProductionWarningListsEveryMissingExplicitValue() {
    var profile = SiteProfile.defaultProfile
    profile.deploymentProvider = .cloudflarePages

    let readiness = DeploymentConfigurationReadiness(profile: profile)

    XCTAssertTrue(readiness.hasExplicitProvider)
    XCTAssertTrue(readiness.issues.contains { $0.contains("生产站点 URL") })
    XCTAssertTrue(readiness.issues.contains { $0.contains("Cloudflare Account ID") })
    XCTAssertTrue(readiness.issues.contains { $0.contains("Cloudflare Pages 项目") })
  }

  func testBackupAndFullyConfiguredOtherPlatformDoNotReportProductionConfigurationWarnings() {
    var backupProfile = SiteProfile.defaultProfile
    backupProfile.purpose = .repositoryBackup

    XCTAssertTrue(DeploymentConfigurationReadiness(profile: backupProfile).issues.isEmpty)

    var vercelProfile = SiteProfile.defaultProfile
    vercelProfile.deploymentProvider = .vercel
    vercelProfile.deploymentProjectID = "project-123"
    vercelProfile.deploymentSiteURL = "https://example.com"

    XCTAssertTrue(DeploymentConfigurationReadiness(profile: vercelProfile).issues.isEmpty)
  }

  func testReadinessDecodesLegacyPayloadWithoutProductionConfigurationFields() throws {
    let legacyPayload = Data(
      #"""
      {
        "provider": "githubPages",
        "isAPIReady": false,
        "canCheckAnyStatus": true,
        "configuredSignals": ["GitHub owner/repository"],
        "missingRequirements": ["部署 Token"],
        "fallbackMessage": "可检查站点 URL",
        "nextStep": "保存 Token"
      }
      """#.utf8
    )

    let readiness = try JSONDecoder().decode(
      DeploymentStatusProviderReadiness.self,
      from: legacyPayload
    )

    XCTAssertTrue(readiness.productionVerificationIssues.isEmpty)
    XCTAssertFalse(readiness.needsExplicitProviderConfirmation)
  }
}
