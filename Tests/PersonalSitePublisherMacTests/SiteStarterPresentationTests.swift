import XCTest
@testable import PersonalSitePublisherMac

final class SiteStarterPresentationTests: XCTestCase {
  func testImportModeProjectionHidesRemotePushStepsEverywhere() {
    XCTAssertEqual(
      SiteStarterWorkflowProjection.steps(mode: .importExisting, deploymentTarget: .githubPages),
      [.template, .localDirectory, .generate, .deployment]
    )
  }

  func testNoDeploymentProjectionHidesRemotePushStepsEverywhere() {
    XCTAssertEqual(
      SiteStarterWorkflowProjection.steps(mode: .create, deploymentTarget: .none),
      [.template, .localDirectory, .generate, .deployment]
    )
  }

  func testDeployingNewSiteRetainsRemoteAndFirstPushReviewSteps() {
    XCTAssertEqual(
      SiteStarterWorkflowProjection.steps(mode: .create, deploymentTarget: .githubPages),
      SiteStarterWizardStep.allCases
    )
  }

  func testSiteStarterFormCannotPersistOldSiteInputsAfterProfileSwitch() {
    let siteA = UUID()
    let siteB = UUID()

    XCTAssertFalse(
      SiteStarterFormProfileBinding.canPersistGitHubInputs(
        boundProfileID: siteA,
        activeProfileID: siteB,
        starterResultProfileID: siteA
      )
    )
    XCTAssertTrue(
      SiteStarterFormProfileBinding.canPersistGitHubInputs(
        boundProfileID: siteB,
        activeProfileID: siteB,
        starterResultProfileID: siteB
      )
    )
  }

  func testGeneratedActiveSiteLocksDeploymentConfigurationButOtherSitesRemainEditable() {
    let generatedSite = UUID()
    let otherSite = UUID()

    XCTAssertTrue(
      SiteStarterDeploymentConfigurationLock.isLocked(
        activeProfileID: generatedSite,
        starterResultProfileID: generatedSite
      )
    )
    XCTAssertFalse(
      SiteStarterDeploymentConfigurationLock.isLocked(
        activeProfileID: otherSite,
        starterResultProfileID: generatedSite
      )
    )
    XCTAssertFalse(
      SiteStarterDeploymentConfigurationLock.isLocked(
        activeProfileID: generatedSite,
        starterResultProfileID: nil
      )
    )
  }
}
