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
}
