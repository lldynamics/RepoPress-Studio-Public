import Foundation
import PublishingDomainContracts
import XCTest

@testable import PublishingWorkbenchCore

@MainActor
final class DeploymentReadinessGuidanceTests: XCTestCase {
  func testCustomProfileWithoutStatusEvidenceDoesNotRequireUnreadToken() {
    var profile = SiteProfile.defaultProfile
    profile.deploymentProvider = .custom
    profile.deploymentSiteURL = nil
    profile.deploymentStatusEndpointURL = nil

    let readiness = DeploymentStore().deploymentStatusReadiness(
      for: profile,
      tokenAvailability: KeychainTokenAvailability(
        hasToken: false,
        accessFailureMessage: "API Base URL 尚未配置。"
      )
    )

    XCTAssertFalse(readiness.canCheckAnyStatus)
    XCTAssertFalse(readiness.missingRequirements.contains(CoreL10n.text("部署 Token")))
    XCTAssertTrue(
      readiness.missingRequirements.contains(CoreL10n.text("站点 URL 或状态端点 URL")))
    XCTAssertEqual(
      readiness.nextStep,
      CoreL10n.format("先补齐 %@。", CoreL10n.text("站点 URL 或状态端点 URL"))
    )
    XCTAssertFalse(readiness.nextStep.contains("API Base URL"))
  }

  func testCustomPublicEndpointIgnoresUnreadOptionalToken() {
    var profile = SiteProfile.defaultProfile
    profile.deploymentProvider = .custom
    profile.deploymentStatusEndpointURL = "https://status.example.com/public"
    profile.deploymentStatusEndpointUsesToken = false

    let readiness = DeploymentStore().deploymentStatusReadiness(
      for: profile,
      tokenAvailability: KeychainTokenAvailability(
        hasToken: false,
        accessFailureMessage: "钥匙串读取失败"
      )
    )

    XCTAssertTrue(readiness.canCheckAnyStatus)
    XCTAssertTrue(readiness.isAPIReady)
    XCTAssertFalse(readiness.missingRequirements.contains(CoreL10n.text("部署 Token")))
    XCTAssertFalse(readiness.fallbackMessage.contains(CoreL10n.text("部署 Token 状态读取失败")))
  }

  func testCustomProtectedEndpointKeepsCredentialFailureSeparateAndActionable() {
    var profile = SiteProfile.defaultProfile
    profile.deploymentProvider = .custom
    profile.deploymentStatusEndpointURL = "https://status.example.com/private"
    profile.deploymentStatusEndpointUsesToken = true

    let readiness = DeploymentStore().deploymentStatusReadiness(
      for: profile,
      tokenAvailability: KeychainTokenAvailability(
        hasToken: false,
        accessFailureMessage: "钥匙串读取失败"
      )
    )

    XCTAssertTrue(readiness.canCheckAnyStatus)
    XCTAssertTrue(readiness.missingRequirements.contains(CoreL10n.text("部署 Token")))
    XCTAssertTrue(readiness.missingRequirements.contains(CoreL10n.text("状态端点 Bearer Token")))
    XCTAssertTrue(readiness.fallbackMessage.contains(CoreL10n.text("部署 Token 状态读取失败")))
    XCTAssertTrue(readiness.nextStep.contains(CoreL10n.text("部署 Token")))
    XCTAssertFalse(readiness.nextStep.contains("钥匙串读取失败"))
  }

  func testProviderTokenFailureKeepsTokenRequirementAndReadableNextStep() {
    var profile = SiteProfile.defaultProfile
    profile.deploymentProvider = .vercel
    profile.deploymentProjectID = "project"

    let readiness = DeploymentStore().deploymentStatusReadiness(
      for: profile,
      tokenAvailability: KeychainTokenAvailability(
        hasToken: false,
        accessFailureMessage: "API Base URL 尚未配置。"
      )
    )

    XCTAssertTrue(readiness.canCheckAnyStatus)
    XCTAssertTrue(readiness.missingRequirements.contains(CoreL10n.text("部署 Token")))
    XCTAssertTrue(readiness.fallbackMessage.contains(CoreL10n.text("部署 Token 状态读取失败")))
    XCTAssertTrue(readiness.nextStep.contains(CoreL10n.text("部署 Token")))
    XCTAssertFalse(readiness.nextStep.contains("API Base URL 尚未配置"))
  }
}
