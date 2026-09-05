import Foundation
import XCTest

@testable import PersonalSitePublisherMac
@testable import PublishingWorkbenchCore

final class RepositoryWorktreePublishPresentationTests: XCTestCase {
  func testDrawerRoutesDefaultActionToWorktreePublisherAndKeepsArticleBatchSecondary() throws {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let sourceURL = repositoryRoot.appendingPathComponent(
      "Sources/PersonalSitePublisherMac/Views/Publishing/PublishDrawerView.swift"
    )
    let source = try String(contentsOf: sourceURL, encoding: .utf8)

    XCTAssertEqual(
      source.components(separatedBy: "publish-drawer-action-publish-all").count - 1,
      1
    )
    XCTAssertEqual(
      source.components(separatedBy: "publish-drawer-action-publish-articles").count - 1,
      1
    )
    XCTAssertEqual(
      source.components(separatedBy: "publish-drawer-action-retry-push").count - 1,
      1
    )
    XCTAssertTrue(source.contains("guard let confirmation = await store.prepareRepositoryWorktreePublish()"))
    XCTAssertTrue(source.contains("await store.publishRepositoryWorktree(confirmation)"))
    XCTAssertTrue(source.contains("await store.prepareRepositoryWorktreePushRetry()"))
    XCTAssertTrue(source.contains("await store.retryRepositoryWorktreePush(confirmation)"))
    XCTAssertTrue(
      source.contains("仍可发布图片、配置、主题、CSS/脚本等仓库变更")
    )
    XCTAssertTrue(source.contains(".disabled(store.isRemoteRepositoryPublishing)"))
  }

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
}
