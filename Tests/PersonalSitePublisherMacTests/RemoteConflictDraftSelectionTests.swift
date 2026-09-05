import PublishingMarkdownCore
import PublishingWorkbenchCore
import XCTest
@testable import PersonalSitePublisherMac

final class RemoteConflictDraftSelectionTests: XCTestCase {
  func testRepeatedMergeDoesNotResetEditedDraft() {
    var state = RemoteConflictDraftSelection()
    state.select(path: "a.md", choice: .merge, local: "local", remote: "remote")
    state.updateMergeDraft("手工合并稿", for: "a.md")
    state.select(path: "a.md", choice: .merge, local: "local", remote: "remote")
    XCTAssertEqual(state.mergeDraft(for: "a.md"), "手工合并稿")
  }

  func testSwitchingAwayAndBackPreservesEachFileAndEmptyDraft() {
    var state = RemoteConflictDraftSelection()
    state.select(path: "a.md", choice: .merge, local: "", remote: "远端")
    state.updateMergeDraft("", for: "a.md")
    state.select(path: "a.md", choice: .useRemote, local: "local", remote: "远端")
    state.select(path: "a.md", choice: .merge, local: "local", remote: "远端")
    state.select(path: "b.md", choice: .merge, local: "另一文件", remote: "远端")
    XCTAssertEqual(state.mergeDraft(for: "a.md"), "")
    XCTAssertEqual(state.mergeDraft(for: "b.md"), "另一文件")
    XCTAssertEqual(state.choice(for: "a.md"), .merge)
  }

  func testReadOnlyChoicesDisplayTheirOwnVersionWithoutReplacingMergeDraft() {
    var state = RemoteConflictDraftSelection()
    XCTAssertEqual(state.displayedDocument(for: "a.md", local: "local", remote: "remote"), "local")
    state.select(path: "a.md", choice: .merge, local: "local", remote: "remote")
    state.updateMergeDraft("edited merge", for: "a.md")
    state.select(path: "a.md", choice: .useRemote, local: "local", remote: "remote")
    XCTAssertEqual(state.displayedDocument(for: "a.md", local: "local", remote: "remote"), "remote")
    state.updateMergeDraft("readonly update must be ignored", for: "a.md")
    state.select(path: "a.md", choice: .keepLocal, local: "local", remote: "remote")
    XCTAssertEqual(state.displayedDocument(for: "a.md", local: "local", remote: "remote"), "local")
    state.select(path: "a.md", choice: .merge, local: "local", remote: "remote")
    XCTAssertEqual(
      state.displayedDocument(for: "a.md", local: "local", remote: "remote"),
      "edited merge"
    )
  }

  func testResolutionPlanRequiresOneValidChoiceForEveryConflict() throws {
    let session = conflictSession(paths: ["content/a.md", "content/b.md"])
    var state = RemoteConflictDraftSelection()

    state.select(
      path: "content/a.md",
      choice: .keepLocal,
      local: "local a",
      remote: "remote a"
    )

    XCTAssertEqual(state.resolvedCount(in: session), 1)
    XCTAssertEqual(state.unresolvedPaths(in: session), ["content/b.md"])
    XCTAssertNil(state.resolutionPlan(for: session))

    state.select(
      path: "content/b.md",
      choice: .useRemote,
      local: "local b",
      remote: "remote b"
    )

    let plan = try XCTUnwrap(state.resolutionPlan(for: session))
    XCTAssertTrue(plan.isComplete(for: session))
    XCTAssertEqual(plan.decisions.map(\.repositoryPath), ["content/a.md", "content/b.md"])
  }

  func testConflictMarkersInAnyMergeDraftBlockWholeResolutionPlan() {
    let session = conflictSession(paths: ["content/a.md", "content/b.md"])
    var state = RemoteConflictDraftSelection()
    state.select(path: "content/a.md", choice: .keepLocal, local: "a", remote: "A")
    state.select(path: "content/b.md", choice: .merge, local: "b", remote: "B")
    state.updateMergeDraft("<<<<<<< ours\nb\n=======\nB\n>>>>>>> theirs", for: "content/b.md")

    XCTAssertEqual(state.resolvedCount(in: session), 1)
    XCTAssertEqual(state.invalidPaths(in: session), ["content/b.md"])
    XCTAssertNil(state.resolutionPlan(for: session))
  }

  func testTruncatedConflictSnapshotCannotProduceResolutionPlan() {
    let visibleItems = conflictSession(paths: ["content/a.md", "content/b.md"])
    let session = RemoteRepositoryConflictSession(
      id: visibleItems.id,
      profileID: visibleItems.profileID,
      repositoryIdentity: visibleItems.repositoryIdentity,
      packageFingerprint: visibleItems.packageFingerprint,
      publishScope: visibleItems.publishScope,
      conflicts: visibleItems.conflicts,
      totalConflictCount: 3
    )
    var state = RemoteConflictDraftSelection()
    for item in session.conflicts {
      state.select(
        path: item.repositoryPath,
        choice: .keepLocal,
        local: item.local.text,
        remote: item.remote.text
      )
    }

    XCTAssertFalse(session.hasCompleteConflictSnapshot)
    XCTAssertNil(state.resolutionPlan(for: session))
  }

  func testSemanticMergeAutomaticallyCombinesIndependentChanges() throws {
    let base = "---\ntitle: Base\ndescription: Old\n---\n\nBody\n"
    let local = "---\ntitle: Local\ndescription: Old\n---\n\nBody\n"
    let remote = "---\ntitle: Base\ndescription: Remote\n---\n\nBody\n"
    let session = conflictSession(path: "content/a.md", base: base, local: local, remote: remote)
    var state = RemoteConflictDraftSelection()

    state.select(
      path: "content/a.md",
      choice: .merge,
      base: base,
      local: local,
      remote: remote
    )

    let mergeState = try XCTUnwrap(state.mergeState(for: "content/a.md"))
    XCTAssertEqual(mergeState.mode, .semantic)
    XCTAssertEqual(mergeState.unresolvedSemanticCount, 0)
    let plan = try XCTUnwrap(state.resolutionPlan(for: session))
    XCTAssertEqual(
      plan.decisions.first?.mergedDocument,
      "---\ntitle: Local\ndescription: Remote\n---\n\nBody\n"
    )
  }

  func testSemanticMergeBlocksTransactionUntilEveryFieldAndBodyHunkIsChosen() throws {
    let base = "---\ntitle: Base\n---\nBase body\n"
    let local = "---\ntitle: Local\n---\nLocal body\n"
    let remote = "---\ntitle: Remote\n---\nRemote body\n"
    let session = conflictSession(path: "content/a.md", base: base, local: local, remote: remote)
    var state = RemoteConflictDraftSelection()
    state.select(
      path: "content/a.md",
      choice: .merge,
      base: base,
      local: local,
      remote: remote
    )

    let initial = try XCTUnwrap(state.mergeState(for: "content/a.md"))
    let field = try XCTUnwrap(initial.semanticPlan?.frontMatterConflicts.first)
    let body = try XCTUnwrap(initial.semanticPlan?.bodyConflicts.first)
    XCTAssertEqual(initial.unresolvedSemanticCount, 2)
    XCTAssertEqual(state.resolvedCount(in: session), 0)
    XCTAssertNil(state.resolutionPlan(for: session))

    state.selectFrontMatterChoice(.local, conflictID: field.id, path: "content/a.md")
    XCTAssertNil(state.resolutionPlan(for: session))
    state.selectBodyChoice(.remote, conflictID: body.id, path: "content/a.md")

    let plan = try XCTUnwrap(state.resolutionPlan(for: session))
    XCTAssertEqual(
      plan.decisions.first?.mergedDocument,
      "---\ntitle: Local\n---\nRemote body\n"
    )
  }

  func testUnsupportedFrontMatterFallsBackToRecoverableFullSource() throws {
    let base = "---\ntitle: Base\ncustom: keep-me\n---\nBody\n"
    let local = "---\ntitle: Local\ncustom: keep-me\n---\nBody\n"
    let remote = "---\ntitle: Remote\ncustom: keep-me\n---\nBody\n"
    let session = conflictSession(path: "content/a.md", base: base, local: local, remote: remote)
    var state = RemoteConflictDraftSelection()
    state.select(
      path: "content/a.md",
      choice: .merge,
      base: base,
      local: local,
      remote: remote
    )

    let fallback = try XCTUnwrap(state.mergeState(for: "content/a.md"))
    XCTAssertEqual(fallback.mode, .source)
    XCTAssertEqual(
      fallback.semanticUnavailableReason,
      .unsupported(.unsupportedFrontMatterKey("custom"))
    )
    XCTAssertEqual(fallback.sourceDraft, local)
    XCTAssertFalse(fallback.sourceReviewed)
    XCTAssertNil(state.resolutionPlan(for: session))

    let manual = "---\ntitle: Reviewed\ncustom: keep-me\n---\nBody\n"
    state.updateMergeDraft(manual, for: "content/a.md")
    XCTAssertEqual(
      try XCTUnwrap(state.resolutionPlan(for: session)).decisions.first?.mergedDocument,
      manual
    )
  }

  func testSwitchingMergeModesPreservesSemanticChoicesAndManualSource() throws {
    let base = "Base\n"
    let local = "Local\n"
    let remote = "Remote\n"
    var state = RemoteConflictDraftSelection()
    state.select(
      path: "content/a.md",
      choice: .merge,
      base: base,
      local: local,
      remote: remote
    )
    let conflict = try XCTUnwrap(
      state.mergeState(for: "content/a.md")?.semanticPlan?.bodyConflicts.first
    )
    state.selectBodyChoice(.both, conflictID: conflict.id, path: "content/a.md")

    state.selectMergeMode(.source, for: "content/a.md")
    state.updateMergeDraft("Manual review\n", for: "content/a.md")
    state.selectMergeMode(.semantic, for: "content/a.md")
    let semantic = try XCTUnwrap(state.mergeState(for: "content/a.md"))
    XCTAssertEqual(semantic.bodyChoices[conflict.id], .both)
    XCTAssertEqual(semantic.semanticResolvedDocument, "Local\nRemote\n")

    state.selectMergeMode(.source, for: "content/a.md")
    XCTAssertEqual(state.mergeState(for: "content/a.md")?.sourceDraft, "Manual review\n")
  }

  func testCopySemanticResultToSourceIsExplicitAndEditable() throws {
    var state = RemoteConflictDraftSelection()
    state.select(
      path: "content/a.md",
      choice: .merge,
      base: "Base\n",
      local: "Local\n",
      remote: "Remote\n"
    )
    let conflict = try XCTUnwrap(
      state.mergeState(for: "content/a.md")?.semanticPlan?.bodyConflicts.first
    )
    state.selectBodyChoice(.local, conflictID: conflict.id, path: "content/a.md")
    state.copySemanticResultToSource(for: "content/a.md")

    XCTAssertEqual(state.mergeState(for: "content/a.md")?.mode, .source)
    XCTAssertEqual(state.mergeState(for: "content/a.md")?.sourceDraft, "Local\n")
    state.updateMergeDraft("Local, reviewed\n", for: "content/a.md")
    XCTAssertEqual(state.mergeState(for: "content/a.md")?.sourceDraft, "Local, reviewed\n")
  }

  func testFullSourceRequiresExplicitReviewEvenWhenTextIsUnchanged() throws {
    let session = conflictSession(
      path: "content/a.md",
      base: "---\ncustom: Base\n---\nBody\n",
      local: "---\ncustom: Local\n---\nBody\n",
      remote: "---\ncustom: Remote\n---\nBody\n"
    )
    var state = RemoteConflictDraftSelection()
    let item = try XCTUnwrap(session.conflicts.first)
    state.select(
      path: item.repositoryPath,
      choice: .merge,
      base: item.base.text,
      local: item.local.text,
      remote: item.remote.text
    )

    XCTAssertNil(state.resolutionPlan(for: session))
    state.confirmSourceDraft(for: item.repositoryPath)
    XCTAssertEqual(
      try XCTUnwrap(state.resolutionPlan(for: session)).decisions.first?.mergedDocument,
      item.local.text
    )
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

  private func conflictSession(
    path: String,
    base: String,
    local: String,
    remote: String
  ) -> RemoteRepositoryConflictSession {
    let profile = SiteProfile.defaultProfile
    return RemoteRepositoryConflictSession(
      profileID: profile.id,
      repositoryIdentity: DraftRepositoryIdentity(profile: profile),
      packageFingerprint: "fingerprint",
      publishScope: .batch([]),
      conflicts: [
        RemoteRepositoryConflictItem(
          repositoryPath: path,
          fileKind: .markdown,
          operation: .upsert,
          expectedSHA: "old",
          actualSHA: "new",
          base: .text(base),
          local: .text(local),
          remote: .text(remote)
        )
      ]
    )
  }
}
