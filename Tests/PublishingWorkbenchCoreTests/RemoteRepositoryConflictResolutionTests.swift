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

  func testResolutionPlanRequiresExactUniqueCoverage() throws {
    let session = conflictSession(paths: ["content/a.md", "content/b.md"])
    let complete = RemoteRepositoryConflictResolutionPlan(
      sessionID: session.id,
      decisions: [
        .init(repositoryPath: "content/a.md", choice: .keepLocal),
        .init(repositoryPath: "content/b.md", choice: .useRemote),
      ]
    )
    XCTAssertEqual(
      try XCTUnwrap(complete.validatedDecisions(for: session)).keys.sorted(),
      ["content/a.md", "content/b.md"]
    )

    let missing = RemoteRepositoryConflictResolutionPlan(
      sessionID: session.id,
      decisions: [.init(repositoryPath: "content/a.md", choice: .keepLocal)]
    )
    XCTAssertNil(missing.validatedDecisions(for: session))

    let duplicate = RemoteRepositoryConflictResolutionPlan(
      sessionID: session.id,
      decisions: [
        .init(repositoryPath: "content/a.md", choice: .keepLocal),
        .init(repositoryPath: "content/a.md", choice: .keepLocal),
      ]
    )
    XCTAssertNil(duplicate.validatedDecisions(for: session))

    let extra = RemoteRepositoryConflictResolutionPlan(
      sessionID: session.id,
      decisions: complete.decisions
        + [.init(repositoryPath: "content/c.md", choice: .keepLocal)]
    )
    XCTAssertNil(extra.validatedDecisions(for: session))
  }

  func testInvalidMergeDecisionRejectsEntirePlan() {
    let session = conflictSession(paths: ["content/a.md", "content/b.md"])
    let plan = RemoteRepositoryConflictResolutionPlan(
      sessionID: session.id,
      decisions: [
        .init(repositoryPath: "content/a.md", choice: .keepLocal),
        .init(
          repositoryPath: "content/b.md",
          choice: .merge,
          mergedDocument: "<<<<<<< ours\nlocal\n=======\nremote\n>>>>>>> theirs"
        ),
      ]
    )

    XCTAssertNil(plan.validatedDecisions(for: session))
  }

  func testMergeDecisionAllowsMarkdownSetextSeparator() {
    let session = conflictSession(paths: ["content/a.md"])
    let plan = RemoteRepositoryConflictResolutionPlan(
      sessionID: session.id,
      decisions: [
        .init(
          repositoryPath: "content/a.md",
          choice: .merge,
          mergedDocument: "Heading\n=======\n\nResolved body\n"
        )
      ]
    )

    XCTAssertTrue(plan.isComplete(for: session))
  }

  func testMergeDecisionRejectsLabeledGitConflictBoundaries() {
    let documents = [
      "<<<<<<< HEAD\nresolved\n",
      "||||||| base\nresolved\n",
      ">>>>>>> branch\nresolved\n",
    ]

    for document in documents {
      let session = conflictSession(paths: ["content/a.md"])
      let plan = RemoteRepositoryConflictResolutionPlan(
        sessionID: session.id,
        decisions: [
          .init(repositoryPath: "content/a.md", choice: .merge, mergedDocument: document)
        ]
      )
      XCTAssertFalse(plan.isComplete(for: session), "Expected marker rejection: \(document)")
    }
  }

  func testMergeDecisionAllowsShortAndUnlabeledBoundaries() {
    let documents = [
      "<<<<<< short marker\nresolved\n",
      "|||||| short marker\nresolved\n",
      ">>>>>> short marker\nresolved\n",
      "Heading\n=======\nresolved\n",
    ]

    for document in documents {
      let session = conflictSession(paths: ["content/a.md"])
      let plan = RemoteRepositoryConflictResolutionPlan(
        sessionID: session.id,
        decisions: [
          .init(repositoryPath: "content/a.md", choice: .merge, mergedDocument: document)
        ]
      )
      XCTAssertTrue(plan.isComplete(for: session), "Unexpected marker rejection: \(document)")
    }
  }

  func testTruncatedSessionCannotBeResolved() {
    let complete = conflictSession(paths: ["content/a.md", "content/b.md"])
    let truncated = RemoteRepositoryConflictSession(
      id: complete.id,
      profileID: complete.profileID,
      repositoryIdentity: complete.repositoryIdentity,
      packageFingerprint: complete.packageFingerprint,
      publishScope: complete.publishScope,
      conflicts: complete.conflicts,
      totalConflictCount: 3
    )
    let plan = RemoteRepositoryConflictResolutionPlan(
      sessionID: truncated.id,
      decisions: truncated.conflicts.map {
        .init(repositoryPath: $0.repositoryPath, choice: .keepLocal)
      }
    )

    XCTAssertFalse(truncated.hasCompleteConflictSnapshot)
    XCTAssertNil(plan.validatedDecisions(for: truncated))
  }

  func testConflictPackageFingerprintDetectsSameSizedMediaReplacement() throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("RemoteConflictMediaFingerprint-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let mediaURL = rootURL.appendingPathComponent("cover.png")
    try Data([1, 2, 3, 4]).write(to: mediaURL)

    var profile = SiteProfile.defaultProfile
    profile.repoOwner = "owner"
    profile.repoName = "site"
    let package = PublishPackage(
      draftID: UUID(),
      title: "Media",
      markdownPath: "content/media.md",
      files: [
        PublishPackageFile(
          kind: .image,
          repositoryPath: "static/cover.png",
          sourceFilePath: mediaURL.path,
          byteSize: 4
        )
      ],
      commitMessage: "Publish media",
      reviewBranchName: "publish/media",
      reviewTitle: "Publish media",
      reviewChecklist: []
    )
    let service = RemoteRepositoryPublishService()
    let first = service.conflictPackageFingerprint(package: package, profile: profile)

    try Data([4, 3, 2, 1]).write(to: mediaURL)
    let second = service.conflictPackageFingerprint(package: package, profile: profile)

    XCTAssertNotEqual(first, second)
  }

  private func conflictSession(paths: [String]) -> RemoteRepositoryConflictSession {
    let profile = SiteProfile.defaultProfile
    return RemoteRepositoryConflictSession(
      profileID: profile.id,
      repositoryIdentity: DraftRepositoryIdentity(profile: profile),
      packageFingerprint: "fingerprint",
      publishScope: .batch([]),
      conflicts: paths.map { path in
        RemoteRepositoryConflictItem(
          repositoryPath: path,
          fileKind: .markdown,
          operation: .upsert,
          expectedSHA: "old-\(path)",
          actualSHA: "new-\(path)",
          base: .text("base \(path)"),
          local: .text("local \(path)"),
          remote: .text("remote \(path)")
        )
      }
    )
  }
}
