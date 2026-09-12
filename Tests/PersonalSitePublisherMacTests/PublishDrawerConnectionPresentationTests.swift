import PublishingWorkbenchCore
import XCTest

@testable import PersonalSitePublisherMac

final class PublishDrawerConnectionPresentationTests: XCTestCase {
  private func preview(hasToken: Bool = true, issues: [PreflightIssue] = [])
    -> RemoteRepositoryPublishPreview
  {
    RemoteRepositoryPublishPreview(
      provider: .github, repositoryName: "example/site", mode: .directCommit,
      branchName: "main", targetBranch: "main", changedPaths: ["post.md"], hasToken: hasToken,
      blockingIssues: issues, warningIssues: [])
  }

  func testUnavailableConnectionAlwaysHasAnExplanationAndRelevantRemedy() {
    let missing = PublishDrawerConnectionPresentation.make(preview: nil)
    XCTAssertFalse(missing.canStart)
    XCTAssertFalse(missing.message.isEmpty)
    XCTAssertEqual(missing.remedy, .refresh)
    let noToken = PublishDrawerConnectionPresentation.make(preview: preview(hasToken: false))
    XCTAssertFalse(noToken.canStart)
    XCTAssertEqual(noToken.remedy, .account)
    XCTAssertFalse(
      PublishDrawerConnectionPresentation.make(preview: preview(), isChecking: true).canStart)
    XCTAssertFalse(
      PublishDrawerConnectionPresentation.make(preview: preview(), isPublishing: true).canStart)
  }

  func testRealBlockerRemainsBlockedButDeferredRemoteCheckCanReachConfirmation() {
    let issue = PreflightIssue(severity: .error, title: "缺少标题", message: "填写标题", field: "title")
    let blocked = PublishDrawerConnectionPresentation.make(preview: preview(issues: [issue]))
    XCTAssertFalse(blocked.canStart)
    XCTAssertEqual(blocked.remedy, .issue(issue))
    let remoteIssue = PreflightIssue(
      severity: .error, title: "待检查", message: "确认前检查", field: "remoteBaseline")
    XCTAssertTrue(
      PublishDrawerConnectionPresentation.make(preview: preview(issues: [remoteIssue])).canStart)
  }

  func testGroupingPreservesAllDetailsStrongestSeverityAndDifferentPaths() {
    let issues: [PreflightIssue] = [
      .init(severity: .warning, title: "未选择仓库", message: "选择根目录", field: "repository"),
      .init(severity: .error, title: "未选择仓库", message: "当前操作需要仓库", field: "repository"),
      .init(
        severity: .warning, title: "图片缺失", message: "找不到图片", field: "attachments",
        relatedValue: "a.png"),
      .init(
        severity: .warning, title: "图片缺失", message: "找不到图片", field: "attachments",
        relatedValue: "b.png"),
    ]
    let grouped = PublishReadinessIssueGrouping.coalesced(issues)
    XCTAssertEqual(grouped.count, 3)
    XCTAssertEqual(grouped[0].severity, .error)
    XCTAssertTrue(grouped[0].message.contains("选择根目录"))
    XCTAssertTrue(grouped[0].message.contains("当前操作需要仓库"))
    XCTAssertEqual(grouped[0].id, issues[0].id)
  }
}
