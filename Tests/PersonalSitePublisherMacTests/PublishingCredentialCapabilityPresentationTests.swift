import PublishingWorkbenchCore
import XCTest

@testable import PersonalSitePublisherMac

final class PublishingCredentialCapabilityPresentationTests: XCTestCase {
  func testSSHGitTransportAndPATArePresentedAsSeparateCredentials() {
    let profile = SiteProfile(
      name: "Personal Site",
      localRepositoryRootPath: "/tmp/site",
      repoOwner: "octocat",
      repoName: "site",
      branch: "main"
    )
    let readiness = DeploymentStatusProviderReadiness(
      provider: .cloudflarePages,
      isAPIReady: false,
      canCheckAnyStatus: false,
      configuredSignals: [],
      missingRequirements: [],
      fallbackMessage: "",
      nextStep: ""
    )

    let presentation = PublishingCredentialCapabilityPresentation.make(
      profile: profile,
      repositoryTokenAvailability: KeychainTokenAvailability(hasToken: true),
      deploymentTokenAvailability: KeychainTokenAvailability(hasToken: false),
      readiness: readiness
    )

    XCTAssertEqual(
      presentation.rows.map(\.id), ["git-transport", "repository-api", "deployment-api"])
    XCTAssertTrue(presentation.rows[0].source.contains("origin"))
    XCTAssertTrue(presentation.rows[0].detail.contains("SSH"))
    XCTAssertTrue(presentation.rows[0].detail.contains("Token 不会自动用于 SSH push"))
    XCTAssertTrue(presentation.rows[1].detail.contains("已保存"))
    XCTAssertTrue(presentation.rows[1].detail.contains("API 权限检查"))
  }

  func testSavedRepositoryTokenIsNotPresentedAsVerifiedPermission() throws {
    let profile = SiteProfile(
      name: "Personal Site",
      localRepositoryRootPath: "/tmp/site",
      repoOwner: "octocat",
      repoName: "site",
      branch: "main"
    )
    let readiness = DeploymentStatusProviderReadiness(
      provider: .netlify,
      isAPIReady: false,
      canCheckAnyStatus: false,
      configuredSignals: [],
      missingRequirements: [],
      fallbackMessage: "",
      nextStep: ""
    )

    let presentation = PublishingCredentialCapabilityPresentation.make(
      profile: profile,
      repositoryTokenAvailability: KeychainTokenAvailability(hasToken: true),
      deploymentTokenAvailability: KeychainTokenAvailability(hasToken: false),
      readiness: readiness
    )

    let repositoryAPI = try XCTUnwrap(presentation.rows.first { $0.id == "repository-api" })
    XCTAssertEqual(repositoryAPI.tone, .neutral)
    XCTAssertFalse(repositoryAPI.detail.contains("权限已验证"))
    XCTAssertTrue(repositoryAPI.detail.contains("仍需运行 API 权限检查"))
  }

  func testDeploymentConfigurationIsNotPresentedAsSuccessfulDeployment() throws {
    let profile = SiteProfile(name: "Personal Site")
    let readiness = DeploymentStatusProviderReadiness(
      provider: .cloudflarePages,
      isAPIReady: true,
      canCheckAnyStatus: true,
      configuredSignals: ["Token", "Project"],
      missingRequirements: [],
      fallbackMessage: "可检查状态",
      nextStep: "运行发布后校验"
    )

    let presentation = PublishingCredentialCapabilityPresentation.make(
      profile: profile,
      repositoryTokenAvailability: KeychainTokenAvailability(hasToken: false),
      deploymentTokenAvailability: KeychainTokenAvailability(hasToken: true),
      readiness: readiness
    )

    let deploymentAPI = try XCTUnwrap(presentation.rows.first { $0.id == "deployment-api" })
    XCTAssertEqual(deploymentAPI.tone, .neutral)
    XCTAssertTrue(deploymentAPI.detail.contains("不代表线上部署成功"))
    XCTAssertTrue(deploymentAPI.detail.contains("不会触发部署"))
  }
}
