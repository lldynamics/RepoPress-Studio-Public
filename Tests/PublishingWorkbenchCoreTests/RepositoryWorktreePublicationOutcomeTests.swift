import PublishingCoreSupport
import XCTest

@testable import PublishingWorkbenchCore

final class RepositoryWorktreePublicationOutcomeTests: XCTestCase {
  func testPushWithoutDeploymentEvidenceIsNotSuccess() {
    let outcome = RepositoryWorktreePublicationOutcome.evaluate(
      result: result,
      articleTarget: target,
      deploymentStatus: nil
    )

    XCTAssertEqual(outcome.feedback.status, .warning)
    XCTAssertFalse(outcome.deploymentVerified)
    XCTAssertFalse(outcome.articleVerified)
    XCTAssertTrue(outcome.feedback.message.contains("不能判定网站发布成功"))
  }

  func testAttributedDeploymentWithoutArticleTargetIsInformational() {
    let outcome = RepositoryWorktreePublicationOutcome.evaluate(
      result: result,
      articleTarget: nil,
      deploymentStatus: snapshot(level: .success, attributionVerified: true)
    )

    XCTAssertEqual(outcome.feedback.status, .information)
    XCTAssertTrue(outcome.deploymentVerified)
    XCTAssertFalse(outcome.articleVerified)
  }

  func testArticleRequiresContentAndSEOProofForSuccess() {
    let status = snapshot(
      level: .success,
      attributionVerified: true,
      signals: [
        signal(title: CoreL10n.text("发布页面内容"), level: .success),
        signal(title: CoreL10n.text("发布页面 SEO"), level: .success),
      ]
    )
    let outcome = RepositoryWorktreePublicationOutcome.evaluate(
      result: result,
      articleTarget: target,
      deploymentStatus: status
    )

    XCTAssertEqual(outcome.feedback.status, .success)
    XCTAssertTrue(outcome.deploymentVerified)
    XCTAssertTrue(outcome.articleVerified)
    XCTAssertTrue(
      RepositoryWorktreePublicationOutcome.verificationIsComplete(
        articleTarget: target,
        deploymentStatus: status
      )
    )
  }

  func testFailedArticlePageProofKeepsPublicationFailed() {
    let status = snapshot(
      level: .success,
      attributionVerified: true,
      signals: [
        signal(title: CoreL10n.text("发布页面内容"), level: .failed),
        signal(title: CoreL10n.text("发布页面 SEO"), level: .success),
      ]
    )
    let outcome = RepositoryWorktreePublicationOutcome.evaluate(
      result: result,
      articleTarget: target,
      deploymentStatus: status
    )

    XCTAssertEqual(outcome.feedback.status, .failure)
    XCTAssertTrue(outcome.deploymentVerified)
    XCTAssertFalse(outcome.articleVerified)
  }

  func testRunningDeploymentRemainsInProgress() {
    let outcome = RepositoryWorktreePublicationOutcome.evaluate(
      result: result,
      articleTarget: target,
      deploymentStatus: snapshot(level: .running, attributionVerified: false)
    )

    XCTAssertEqual(outcome.feedback.status, .inProgress)
    XCTAssertFalse(outcome.articleVerified)
  }

  private var result: RepositoryWorktreePublishResult {
    RepositoryWorktreePublishResult(
      commitSHA: "0123456789abcdef",
      branch: "main",
      pushed: true,
      remoteCommitSHA: "0123456789abcdef",
      committedPaths: ["content/posts/article.md"]
    )
  }

  private var target: RepositoryWorktreeArticleVerificationTarget {
    RepositoryWorktreeArticleVerificationTarget(
      draftID: UUID(),
      title: "文章",
      summary: "摘要",
      markdownPath: "content/posts/article.md"
    )
  }

  private func snapshot(
    level: DeploymentStatusLevel,
    attributionVerified: Bool,
    signals: [DeploymentStatusSignal] = []
  ) -> DeploymentStatusSnapshot {
    DeploymentStatusSnapshot(
      profileID: UUID(),
      releaseRecordID: UUID(),
      provider: .cloudflarePages,
      level: level,
      title: "部署",
      message: "状态",
      siteURLText: "https://example.com",
      signals: signals,
      expectedBranch: "main",
      expectedCommitSHA: result.commitSHA,
      observedBranch: "main",
      observedCommitSHA: result.commitSHA,
      attributionVerified: attributionVerified
    )
  }

  private func signal(
    title: String,
    level: DeploymentStatusLevel
  ) -> DeploymentStatusSignal {
    DeploymentStatusSignal(
      level: level,
      title: title,
      message: "证据"
    )
  }
}
