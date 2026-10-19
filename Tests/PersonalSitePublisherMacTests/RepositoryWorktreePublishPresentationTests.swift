import Foundation
import XCTest

@testable import PersonalSitePublisherMac
@testable import PublishingWorkbenchCore

final class RepositoryWorktreePublishPresentationTests: XCTestCase {
  func testFormatsTargetSHAsAndRenameAsFrozenReviewEvidence() {
    let entry = RepositoryWorktreePublishEntry(
      kind: .renamed,
      status: " R",
      path: "content/new-name.md",
      sourcePath: "content/old-name.md",
      byteSize: 1_024,
      mode: "100755",
      blobOID: "blob"
    )

    XCTAssertEqual(
      RepositoryWorktreePublishPresentation.shortSHA("1234567890abcdef"),
      "1234567890ab"
    )
    XCTAssertEqual(
      RepositoryWorktreePublishPresentation.pathDescription(for: entry),
      "content/old-name.md → content/new-name.md"
    )
    XCTAssertEqual(
      RepositoryWorktreePublishPresentation.metadataDescription(for: entry),
      " R · mode 100755"
    )
  }

  func testDescribesDeletedPathWithoutInventingAMode() {
    let entry = RepositoryWorktreePublishEntry(
      kind: .deleted,
      status: " D",
      path: "content/removed.md"
    )

    XCTAssertEqual(
      RepositoryWorktreePublishPresentation.metadataDescription(for: entry),
      " D · 已从索引删除"
    )
    XCTAssertTrue(
      RepositoryWorktreePublishPresentation.accessibilityLabel(for: entry).contains("删除")
    )
  }

  func testClassifiesArticleBodyImagesAndDestructiveOperations() {
    let entries = [
      RepositoryWorktreePublishEntry(kind: .modified, status: " M", path: "content/a.md"),
      RepositoryWorktreePublishEntry(kind: .added, status: "??", path: "content/a-cover.webp"),
      RepositoryWorktreePublishEntry(
        kind: .renamed, status: " R", path: "content/new.png", sourcePath: "content/old.png"),
      RepositoryWorktreePublishEntry(kind: .deleted, status: " D", path: "content/old.md"),
    ]

    let summary = RepositoryWorktreePublishPresentation.contentChangeSummary(
      entries: entries, articlePath: "content/a.md")
    XCTAssertEqual(summary.bodyOperations, ["修改"])
    XCTAssertEqual(summary.imageOperations, ["新增", "重命名"])
    XCTAssertEqual(summary.otherOperations, ["删除"])
    XCTAssertEqual(summary.riskPaths, ["content/old.png → content/new.png", "content/old.md"])
    XCTAssertEqual(RepositoryWorktreePublishPresentation.operationLabel(for: entries[2]), "重命名")
  }

  func testMissingArticlePathStillProducesHonestSummary() {
    let summary = RepositoryWorktreePublishPresentation.contentChangeSummary(
      entries: [
        RepositoryWorktreePublishEntry(kind: .modified, status: " M", path: "content/a.md")
      ],
      articlePath: nil)
    XCTAssertTrue(summary.bodyOperations.isEmpty)
    XCTAssertEqual(summary.otherOperations, ["修改"])
  }

  func testBlockingIssueCannotBeConfirmedEvenAfterAcknowledgement() {
    XCTAssertFalse(
      RepositoryWorktreePublishConfirmationPresentationPolicy.canConfirm(
        isPublishing: false,
        isReviewComplete: true,
        requiresAcknowledgement: true,
        acknowledgementGiven: true,
        hasBlockingIssue: true
      ))
  }
}

final class RepositoryWorktreePublishConfirmationPresentationPolicyTests: XCTestCase {
  func testSafetyWarningRequiresAcknowledgement() {
    XCTAssertTrue(
      RepositoryWorktreePublishConfirmationPresentationPolicy.requiresAcknowledgement(
        safetyWarningCount: 1,
        articleWarningCount: 0,
        sitePreflight: nil
      ))
    XCTAssertFalse(canConfirm(requiresAcknowledgement: true, acknowledgementGiven: false))
    XCTAssertTrue(canConfirm(requiresAcknowledgement: true, acknowledgementGiven: true))
  }

  func testOutgoingHistoryRequiresExplicitAcknowledgement() {
    XCTAssertFalse(
      RepositoryWorktreePublishConfirmationPresentationPolicy.canConfirm(
        isPublishing: false,
        isReviewComplete: true,
        requiresAcknowledgement: false,
        acknowledgementGiven: false,
        historyReviewComplete: true,
        historyAcknowledgementGiven: false
      ))
    XCTAssertTrue(
      RepositoryWorktreePublishConfirmationPresentationPolicy.canConfirm(
        isPublishing: false,
        isReviewComplete: true,
        requiresAcknowledgement: false,
        acknowledgementGiven: false,
        historyReviewComplete: true,
        historyAcknowledgementGiven: true
      ))
  }

  func testIncompleteOutgoingHistoryCannotBeConfirmed() {
    XCTAssertFalse(
      RepositoryWorktreePublishConfirmationPresentationPolicy.canConfirm(
        isPublishing: false,
        isReviewComplete: true,
        requiresAcknowledgement: true,
        acknowledgementGiven: true,
        historyReviewComplete: false,
        historyAcknowledgementGiven: true
      ))
  }

  func testOptionalOptimizationDoesNotRequireAcknowledgement() {
    let issue = PreflightIssue(
      severity: .warning,
      title: "标题较短",
      message: "可补充更多内容",
      ruleID: ContentHealthRuleID.shortBody.rawValue
    )
    XCTAssertEqual(
      RepositoryWorktreePublishConfirmationPresentationPolicy.optionalIssues(from: [issue]).count,
      1)
    XCTAssertFalse(
      RepositoryWorktreePublishConfirmationPresentationPolicy.requiresAcknowledgement(
        safetyWarningCount: 0,
        articleWarningCount: 0,
        sitePreflight: nil
      ))
    XCTAssertTrue(canConfirm(requiresAcknowledgement: false, acknowledgementGiven: false))
  }

  func testFailedSitePreflightRequiresAcknowledgementAndSkippedIsOptional() {
    let failed = RepositoryPublishPreflightResult(
      outcome: .failed(.checkFailed), message: "检查失败")
    XCTAssertTrue(
      RepositoryWorktreePublishConfirmationPresentationPolicy.requiresAcknowledgement(
        safetyWarningCount: 0,
        articleWarningCount: 0,
        sitePreflight: failed
      ))
    XCTAssertFalse(canConfirm(requiresAcknowledgement: true, acknowledgementGiven: false))

    let skipped = RepositoryPublishPreflightResult(
      outcome: .skipped(.nonZolaProfile), message: "未执行")
    XCTAssertFalse(
      RepositoryWorktreePublishConfirmationPresentationPolicy.requiresAcknowledgement(
        safetyWarningCount: 0,
        articleWarningCount: 0,
        sitePreflight: skipped
      ))
    XCTAssertTrue(
      RepositoryWorktreePublishConfirmationPresentationPolicy.isSkipped(skipped))
  }

  private func canConfirm(
    requiresAcknowledgement: Bool,
    acknowledgementGiven: Bool
  ) -> Bool {
    RepositoryWorktreePublishConfirmationPresentationPolicy.canConfirm(
      isPublishing: false,
      isReviewComplete: true,
      requiresAcknowledgement: requiresAcknowledgement,
      acknowledgementGiven: acknowledgementGiven
    )
  }
}
