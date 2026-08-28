import XCTest
@testable import PersonalSitePublisherMac
@testable import PublishingWorkbenchCore

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
}
