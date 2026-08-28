import PublishingGitCore
import XCTest

@testable import PublishingWorkbenchCore

final class RemoteRepositoryConflictResolutionTests: XCTestCase {
  func testResolutionOutcomeOnlyDismissesTerminalStates() {
    XCTAssertTrue(
      RemoteRepositoryConflictResolutionOutcome.completed(message: "done")
        .shouldDismissResolver
    )
    XCTAssertTrue(
      RemoteRepositoryConflictResolutionOutcome.sessionInvalidated(message: "stale")
        .shouldDismissResolver
    )
    XCTAssertFalse(
      RemoteRepositoryConflictResolutionOutcome.sessionRefreshed(message: "refresh")
        .shouldDismissResolver
    )
    XCTAssertFalse(
      RemoteRepositoryConflictResolutionOutcome.failed(message: "retry")
        .shouldDismissResolver
    )
  }

  func testReviewedRemoteBaselineKeepsMergedDocumentAsLocalChange() {
    var profile = SiteProfile.defaultProfile
    profile.repoOwner = "owner"
    profile.repoName = "site"
    profile.branch = "main"
    var draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Merged",
      slug: "merged",
      bodyMarkdown: "Merged body"
    )

    draft.adoptReviewedRemoteBaseline(
      profile: profile,
      repositoryPath: "content/posts/merged.md",
      remoteRevision: "actual-sha",
      remoteDocument: "remote document",
      localDocument: "merged document"
    )

    XCTAssertEqual(draft.repositorySHA, "actual-sha")
    XCTAssertEqual(draft.repositoryBinding?.syncState, .localChanged)
    XCTAssertEqual(
      draft.repositoryBinding?.renderedContentDigest,
      ArticleDraft.repositoryDocumentDigest("remote document")
    )
    XCTAssertNil(draft.repositoryImportFingerprint)
  }

  func testReviewedRemoteBaselineMarksIdenticalRemoteDocumentSynced() {
    let profile = SiteProfile.defaultProfile
    var draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Remote",
      slug: "remote",
      bodyMarkdown: "Remote body"
    )

    draft.adoptReviewedRemoteBaseline(
      profile: profile,
      repositoryPath: "content/posts/remote.md",
      remoteRevision: "actual-sha",
      remoteDocument: "same document",
      localDocument: "same document"
    )

    XCTAssertEqual(draft.repositoryBinding?.syncState, .synced)
    XCTAssertNotNil(draft.repositoryImportFingerprint)
  }

  func testMediaConflictCannotEnterTextMergeOrRemoteImport() {
    let item = RemoteRepositoryConflictItem(
      repositoryPath: "static/image.png",
      fileKind: .image,
      operation: .upsert,
      expectedSHA: "old",
      actualSHA: "new",
      base: .diagnostic(.binary, message: "binary"),
      local: .diagnostic(.binary, message: "binary"),
      remote: .diagnostic(.binary, message: "binary")
    )

    XCTAssertTrue(item.canKeepLocalOperation)
    XCTAssertFalse(item.canUseRemoteText)
    XCTAssertFalse(item.canMergeText)
  }

  func testDeleteConflictAlwaysOffersSafeReviewRequestEscapeHatch() {
    let item = RemoteRepositoryConflictItem(
      repositoryPath: "content/posts/retired.md",
      fileKind: .markdown,
      operation: .delete,
      expectedSHA: "old",
      actualSHA: "new",
      base: .text("base"),
      local: .missing("scheduled for deletion"),
      remote: .text("remote")
    )

    XCTAssertTrue(item.canKeepLocalOperation)
    XCTAssertFalse(item.canUseRemoteText)
    XCTAssertFalse(item.canMergeText)
  }

  func testUnavailableRemoteTextStillAllowsKeepingLocalOperation() {
    let item = RemoteRepositoryConflictItem(
      repositoryPath: "content/posts/article.md",
      fileKind: .markdown,
      operation: .upsert,
      expectedSHA: "old",
      actualSHA: "new",
      base: .text("base"),
      local: .text("local"),
      remote: .diagnostic(.unavailable, message: "missing provider content")
    )

    XCTAssertTrue(item.canKeepLocalOperation)
    XCTAssertFalse(item.canUseRemoteText)
    XCTAssertFalse(item.canMergeText)
  }
}
