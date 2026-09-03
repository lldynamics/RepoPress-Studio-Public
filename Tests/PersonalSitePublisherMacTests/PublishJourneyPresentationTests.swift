import PublishingWorkbenchCore
import XCTest

@testable import PersonalSitePublisherMac

final class PublishJourneyPresentationTests: XCTestCase {
  private func profile(_ configure: (inout SiteProfile) -> Void = { _ in }) -> SiteProfile {
    var value = SiteProfile.defaultProfile
    value.repoOwner = "owner"
    value.repoName = "site"
    value.deploymentProvider = .githubPages
    value.deploymentSiteURL = "https://example.com"
    configure(&value)
    return value
  }

  private func preview(_ configure: (inout RemoteRepositoryPublishPreview) -> Void = { _ in })
    -> RemoteRepositoryPublishPreview
  {
    var value = RemoteRepositoryPublishPreview(
      provider: .github, repositoryName: "owner/site", mode: .directCommit, branchName: "main",
      targetBranch: "main", changedPaths: ["content/post.md"], remoteRiskState: .clean,
      hasToken: true,
      accessCheck: RemoteRepositoryAccessCheck(
        provider: .github, repositoryName: "owner/site", defaultBranch: "main", canRead: true,
        canWrite: true, message: "ok"), blockingIssues: [], warningIssues: [])
    configure(&value)
    return value
  }

  func testMissingRepositoryDisablesAndPointsToRepositorySettings() {
    var p = profile()
    p.repoOwner = ""
    let result = PublishJourneyPresentation.make(
      profile: p, preview: preview(), isWebsiteDraft: false, isPreparing: false,
      isPublishing: false, progressStage: nil, latestRecord: nil, deploymentSnapshot: nil)
    XCTAssertEqual(result.settingsTarget, .repository)
    XCTAssertFalse(result.isPrimaryActionEnabled)
    XCTAssertEqual(result.steps[id: "prepare"]?.status, .blocked)
    XCTAssertEqual(result.steps[id: "upload"]?.status, .upcoming)
  }

  func testMissingTokenDisables() {
    let result = PublishJourneyPresentation.make(
      profile: profile(), preview: preview { $0.hasToken = false }, isWebsiteDraft: false,
      isPreparing: false, isPublishing: false, progressStage: nil, latestRecord: nil,
      deploymentSnapshot: nil)
    XCTAssertEqual(result.settingsTarget, .repository)
    XCTAssertFalse(result.isPrimaryActionEnabled)
  }

  func testDeploymentConfigurationDoesNotBlockRemoteWrite() {
    let result = PublishJourneyPresentation.make(
      profile: profile { $0.deploymentSiteURL = nil }, preview: preview(), isWebsiteDraft: false,
      isPreparing: false, isPublishing: false, progressStage: nil, latestRecord: nil,
      deploymentSnapshot: nil)
    XCTAssertEqual(result.settingsTarget, .deployment)
    XCTAssertEqual(result.settingsActionTitle, "完善部署验证")
    XCTAssertTrue(result.isPrimaryActionEnabled)
    XCTAssertTrue(result.configurationMessage?.contains("可以推送") == true)
  }

  func testDirectCommitIsWrittenButDeploymentRemainsPending() {
    let record = ReleaseRecord(
      kind: .remoteDirectCommit,
      title: "Published",
      summary: "Remote commit created",
      commitSHA: "direct123"
    )
    let result = PublishJourneyPresentation.make(
      profile: profile(),
      preview: preview(),
      isWebsiteDraft: false,
      isPreparing: false,
      isPublishing: false,
      progressStage: .completed,
      latestRecord: record,
      deploymentSnapshot: nil
    )

    XCTAssertEqual(result.steps[id: "prepare"]?.status, .complete)
    XCTAssertEqual(result.steps[id: "upload"]?.status, .complete)
    XCTAssertEqual(result.steps[id: "reviewOrTarget"]?.status, .complete)
    XCTAssertEqual(result.steps[id: "onlineVerification"]?.status, .active)
  }

  func testDraftHasOnlyPrepareAndUpload() {
    let result = PublishJourneyPresentation.make(
      profile: profile(), preview: preview { $0.mode = .previewBranch }, isWebsiteDraft: true,
      isPreparing: false, isPublishing: false, progressStage: nil, latestRecord: nil,
      deploymentSnapshot: nil)
    XCTAssertEqual(result.steps.map(\.id), ["prepare", "upload"])
    XCTAssertEqual(result.primaryActionTitle, "同步网站草稿…")
  }

  func testWaitingPRIsActiveAndMergedMatchingDeploymentCompletesVerification() {
    let waiting = ReleaseRecord(
      kind: .remoteReviewRequest, title: "x", summary: "x", commitSHA: "head",
      reviewStatus: RemoteRepositoryReviewStatusSnapshot(
        provider: .github, reviewNumber: 1, reviewURL: "https://github.com", state: .open,
        sourceBranch: "publish", targetBranch: "main"))
    let pending = PublishJourneyPresentation.make(
      profile: profile(), preview: preview { $0.mode = .reviewRequest }, isWebsiteDraft: false,
      isPreparing: false, isPublishing: false, progressStage: nil, latestRecord: waiting,
      deploymentSnapshot: nil)
    XCTAssertEqual(pending.steps[id: "reviewOrTarget"]?.status, .active)

    var merged = waiting
    merged.reviewStatus?.state = .merged
    merged.reviewStatus?.mergeCommitSHA = "merge123"
    let snapshot = DeploymentStatusSnapshot(
      profileID: profile().id, releaseRecordID: merged.id, provider: .githubPages, level: .success,
      title: "ok", message: "ok", siteURLText: "https://example.com", signals: [],
      expectedCommitSHA: "merge123", observedCommitSHA: "merge123", attributionVerified: true)
    let complete = PublishJourneyPresentation.make(
      profile: profile(), preview: preview { $0.mode = .reviewRequest }, isWebsiteDraft: false,
      isPreparing: false, isPublishing: false, progressStage: nil, latestRecord: merged,
      deploymentSnapshot: snapshot)
    XCTAssertEqual(complete.steps[id: "reviewOrTarget"]?.status, .complete)
    XCTAssertEqual(complete.steps[id: "onlineVerification"]?.status, .complete)
  }

  func testFailedProgressBlocksUpload() {
    let result = PublishJourneyPresentation.make(
      profile: profile(), preview: preview(), isWebsiteDraft: false, isPreparing: false,
      isPublishing: true, progressStage: .failed, latestRecord: nil, deploymentSnapshot: nil)
    XCTAssertEqual(result.steps[id: "upload"]?.status, .blocked)
  }
}

extension Array where Element == PublishJourneyStep {
  fileprivate subscript(id id: String) -> Element? { first { $0.id == id } }
}
