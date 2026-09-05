import PublishingGitCore
import PublishingMarkdownCore
import XCTest

@testable import PersonalSitePublisherMac

final class RepositoryMergeConflictSemanticDraftTests: XCTestCase {
  func testAutomaticallyMergedMarkdownIsImmediatelyAvailableInSemanticMode() {
    let conflict = markdownConflict(
      base: "---\ntitle: Base\n---\nBody\n",
      ours: "---\ntitle: Local\n---\nBody\n",
      theirs: "---\ntitle: Base\n---\nRemote body\n"
    )

    let draft = RepositoryMergeConflictSemanticDraft(conflict: conflict)

    XCTAssertEqual(draft.mode, .semantic)
    XCTAssertEqual(draft.unresolvedSemanticCount, 0)
    XCTAssertEqual(draft.semanticResolvedDocument, "---\ntitle: Local\n---\nRemote body\n")
    XCTAssertEqual(draft.resolvedDocument, draft.semanticResolvedDocument)
    XCTAssertTrue(draft.canApply)
  }

  func testSemanticResultIsGatedUntilEveryFieldAndHunkHasChoice() {
    var draft = RepositoryMergeConflictSemanticDraft(conflict: overlappingMarkdownConflict())
    let plan = try! XCTUnwrap(draft.semanticPlan)

    XCTAssertGreaterThan(plan.frontMatterConflicts.count + plan.bodyConflicts.count, 0)
    XCTAssertNil(draft.semanticResolvedDocument)
    XCTAssertNil(draft.resolvedDocument)

    selectAllRemote(&draft, plan: plan)

    XCTAssertEqual(draft.unresolvedSemanticCount, 0)
    XCTAssertNotNil(draft.semanticResolvedDocument)
    XCTAssertNotNil(draft.resolvedDocument)
  }

  func testComplexFrontMatterFallsBackAndPreservesWorkingTreeFinalVerbatim() {
    let final = "---\n# preserve this exact source\ntitle: Working\n---\nFinal\n"
    let conflict = markdownConflict(
      base: "---\n# note\ntitle: Base\n---\nBody\n",
      ours: "---\n# note\ntitle: Local\n---\nBody\n",
      theirs: "---\n# note\ntitle: Remote\n---\nBody\n",
      final: final
    )

    let draft = RepositoryMergeConflictSemanticDraft(conflict: conflict)

    XCTAssertEqual(draft.mode, .source)
    XCTAssertNotNil(draft.semanticUnavailableReason)
    XCTAssertEqual(draft.sourceDraft, final)
    XCTAssertNil(draft.resolvedDocument)
  }

  func testSourceRequiresEditOrExplicitConfirmation() {
    let conflict = markdownConflict(
      path: "content/notes.txt",
      base: "base\n",
      ours: "local\n",
      theirs: "remote\n",
      final: "working tree\n"
    )
    var draft = RepositoryMergeConflictSemanticDraft(conflict: conflict)

    XCTAssertEqual(draft.mode, .source)
    XCTAssertFalse(draft.sourceReviewed)
    XCTAssertNil(draft.resolvedDocument)

    draft.confirmSourceDraft()
    XCTAssertEqual(draft.resolvedDocument, "working tree\n")
    XCTAssertTrue(draft.canApply)
  }

  func testConfirmedSourceWithGitMarkersStillCannotApply() {
    let conflict = markdownConflict(
      path: "content/notes.txt",
      final: "<<<<<<< HEAD\nlocal\n=======\nremote\n>>>>>>> feature\n"
    )
    var draft = RepositoryMergeConflictSemanticDraft(conflict: conflict)

    draft.confirmSourceDraft()

    XCTAssertNotNil(draft.resolvedDocument)
    XCTAssertFalse(draft.canApply)
  }

  func testModeSwitchKeepsSemanticChoicesAndSeparateSourceDraft() throws {
    var draft = RepositoryMergeConflictSemanticDraft(conflict: overlappingMarkdownConflict())
    let plan = try XCTUnwrap(draft.semanticPlan)
    let field = try XCTUnwrap(plan.frontMatterConflicts.first)
    draft.selectFrontMatterChoice(.local, conflictID: field.id)
    let source = draft.sourceDraft

    draft.selectMode(.source)
    draft.updateSourceDraft("manual source\n")
    draft.selectMode(.semantic)

    XCTAssertEqual(draft.frontMatterChoices[field.id], .local)
    XCTAssertEqual(draft.sourceDraft, "manual source\n")
    XCTAssertNotEqual(draft.sourceDraft, source)
  }

  func testQuickChoiceCopiesExactSideMarksReviewedAndKeepsSemanticChoices() throws {
    let conflict = overlappingMarkdownConflict()
    var draft = RepositoryMergeConflictSemanticDraft(conflict: conflict)
    let plan = try XCTUnwrap(draft.semanticPlan)
    let field = try XCTUnwrap(plan.frontMatterConflicts.first)
    draft.selectFrontMatterChoice(.remote, conflictID: field.id)

    draft.prepareQuickChoice(.ours)

    XCTAssertEqual(draft.mode, .source)
    XCTAssertTrue(draft.sourceReviewed)
    XCTAssertEqual(draft.sourceDraft, conflict.ours.text)
    XCTAssertEqual(draft.frontMatterChoices[field.id], .remote)
    XCTAssertEqual(draft.resolvedDocument, conflict.ours.text)
  }

  func testMissingBinaryAndNonMarkdownAlwaysFailClosedToSource() {
    let missing = RepositoryMergeConflict(
      repositoryPath: "content/post.md",
      base: .missing(),
      ours: .text("local\n"),
      theirs: .text("remote\n"),
      final: .text("working\n")
    )
    let binary = RepositoryMergeConflict(
      repositoryPath: "content/post.md",
      base: .text("base\n"),
      ours: .diagnostic(.binary, message: "binary"),
      theirs: .text("remote\n"),
      final: .text("working\n")
    )
    let binaryFinal = RepositoryMergeConflict(
      repositoryPath: "content/post.md",
      base: .text("base\n"),
      ours: .text("local\n"),
      theirs: .text("remote\n"),
      final: .diagnostic(.binary, message: "binary working tree")
    )
    let nonMarkdown = markdownConflict(path: "content/post.html")

    XCTAssertEqual(RepositoryMergeConflictSemanticDraft(conflict: missing).mode, .source)
    var binaryDraft = RepositoryMergeConflictSemanticDraft(conflict: binary)
    XCTAssertEqual(binaryDraft.mode, .source)
    binaryDraft.confirmSourceDraft()
    binaryDraft.prepareQuickChoice(.theirs)
    XCTAssertNil(binaryDraft.resolvedDocument)
    XCTAssertFalse(binaryDraft.canApply)
    let binaryFinalDraft = RepositoryMergeConflictSemanticDraft(conflict: binaryFinal)
    XCTAssertEqual(binaryFinalDraft.mode, .source)
    XCTAssertNil(binaryFinalDraft.semanticPlan)
    XCTAssertNil(binaryFinalDraft.resolvedDocument)
    XCTAssertFalse(binaryFinalDraft.canApply)
    XCTAssertEqual(RepositoryMergeConflictSemanticDraft(conflict: nonMarkdown).mode, .source)
  }

  func testSnapshotRejectsSamePathWhenContentOrStageChanges() {
    let original = markdownConflict(final: "working\n")
    let draft = RepositoryMergeConflictSemanticDraft(conflict: original)
    var changedContent = original
    changedContent.final = .text("new working tree\n")
    var changedStage = original
    changedStage.stageEntries = [
      RepositoryMergeConflictIndexEntry(
        mode: "100644", objectSHA: "abc", stage: .ours, repositoryPath: original.repositoryPath
      )
    ]

    XCTAssertTrue(draft.matches(original))
    XCTAssertFalse(draft.matches(changedContent))
    XCTAssertFalse(draft.matches(changedStage))
  }

  func testDeleteSelectionBuildsSnapshotBoundRequestAndSourceReviewClearsIt() throws {
    let path = "content/post.md"
    let conflict = RepositoryMergeConflict(
      repositoryPath: path,
      base: .text("base\n"),
      ours: .missing(),
      theirs: .text("remote modification\n"),
      final: .text("remote modification\n"),
      stageEntries: [
        stage(.base, path: path, sha: "base-sha"),
        stage(.theirs, path: path, sha: "theirs-sha"),
      ],
      workingTreeContentSHA: "working-tree-sha"
    )
    var draft = RepositoryMergeConflictSemanticDraft(conflict: conflict)

    draft.selectDeletion()

    XCTAssertTrue(draft.isDeletionSelected)
    XCTAssertTrue(draft.canApply)
    let request = try XCTUnwrap(draft.resolutionRequest)
    XCTAssertEqual(request.expectation, conflict.resolutionExpectation)
    XCTAssertEqual(request.resolution, .delete)

    draft.confirmSourceDraft()

    XCTAssertFalse(draft.isDeletionSelected)
    XCTAssertEqual(draft.resolutionRequest?.resolution, .finalText("remote modification\n"))
  }

  func testBinaryModifyDeleteCanSelectDeletionButUnsafeShapesFailClosed() {
    let path = "static/image.bin"
    let binaryDelete = RepositoryMergeConflict(
      repositoryPath: path,
      base: .diagnostic(.binary, message: "binary base"),
      ours: .missing(),
      theirs: .diagnostic(.binary, message: "binary remote"),
      final: .diagnostic(.binary, message: "binary working tree"),
      stageEntries: [
        stage(.base, path: path, sha: "base-sha"),
        stage(.theirs, path: path, sha: "theirs-sha"),
      ],
      workingTreeContentSHA: "working-tree-sha"
    )
    var binaryDraft = RepositoryMergeConflictSemanticDraft(conflict: binaryDelete)
    binaryDraft.selectDeletion()
    XCTAssertFalse(binaryDelete.canResolve)
    XCTAssertTrue(binaryDraft.canApply)
    XCTAssertEqual(binaryDraft.resolutionRequest?.resolution, .delete)

    var modifyModifyDraft = RepositoryMergeConflictSemanticDraft(conflict: markdownConflict())
    modifyModifyDraft.selectDeletion()
    XCTAssertFalse(modifyModifyDraft.isDeletionSelected)

    var missingHash = binaryDelete
    missingHash.workingTreeContentSHA = nil
    var missingHashDraft = RepositoryMergeConflictSemanticDraft(conflict: missingHash)
    missingHashDraft.selectDeletion()
    XCTAssertFalse(missingHashDraft.isDeletionSelected)
    XCTAssertNil(missingHashDraft.resolutionRequest)
  }

  func testSetextHeadingDividerRemainsEligibleMarkdown() {
    let conflict = markdownConflict(
      base: "Heading\n=======\nBase\n",
      ours: "Heading\n=======\nLocal\n",
      theirs: "Heading\n=======\nRemote\n"
    )
    let draft = RepositoryMergeConflictSemanticDraft(conflict: conflict)

    XCTAssertEqual(draft.mode, .semantic)
  }

  private func selectAllRemote(
    _ draft: inout RepositoryMergeConflictSemanticDraft,
    plan: MarkdownThreeWayMergePlan
  ) {
    for conflict in plan.frontMatterConflicts {
      draft.selectFrontMatterChoice(.remote, conflictID: conflict.id)
    }
    for conflict in plan.bodyConflicts {
      draft.selectBodyChoice(.remote, conflictID: conflict.id)
    }
  }

  private func overlappingMarkdownConflict() -> RepositoryMergeConflict {
    markdownConflict(
      base: "---\ntitle: Base\n---\nParagraph\n",
      ours: "---\ntitle: Local\n---\nLocal paragraph\n",
      theirs: "---\ntitle: Remote\n---\nRemote paragraph\n"
    )
  }

  private func markdownConflict(
    path: String = "content/post.md",
    base: String = "base\n",
    ours: String = "local\n",
    theirs: String = "remote\n",
    final: String? = nil
  ) -> RepositoryMergeConflict {
    RepositoryMergeConflict(
      repositoryPath: path,
      base: .text(base),
      ours: .text(ours),
      theirs: .text(theirs),
      final: .text(final ?? ours),
      stageEntries: [
        stage(.base, path: path, sha: "base-sha"),
        stage(.ours, path: path, sha: "ours-sha"),
        stage(.theirs, path: path, sha: "theirs-sha"),
      ],
      workingTreeContentSHA: "working-tree-sha"
    )
  }

  private func stage(
    _ stage: RepositoryMergeConflictStage,
    path: String,
    sha: String
  ) -> RepositoryMergeConflictIndexEntry {
    RepositoryMergeConflictIndexEntry(
      mode: "100644",
      objectSHA: sha,
      stage: stage,
      repositoryPath: path
    )
  }
}
