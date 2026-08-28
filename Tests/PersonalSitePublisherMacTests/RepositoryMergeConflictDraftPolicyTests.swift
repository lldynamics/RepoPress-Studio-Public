import PublishingGitCore
import XCTest

@testable import PersonalSitePublisherMac

final class RepositoryMergeConflictDraftPolicyTests: XCTestCase {
  func testSideChoicesPrepareExactTextWithoutResolving() {
    let conflict = makeConflict(final: "working")

    XCTAssertEqual(
      RepositoryMergeConflictDraftPolicy.preparedText(for: .ours, conflict: conflict),
      "local\n"
    )
    XCTAssertEqual(
      RepositoryMergeConflictDraftPolicy.preparedText(for: .theirs, conflict: conflict),
      "remote\n"
    )
  }

  func testManualMergeRemovesDiff3MarkersAndBaseSection() {
    let conflict = makeConflict(
      final: """
        before
        <<<<<<< HEAD
        local
        ||||||| base
        old
        =======
        remote
        >>>>>>> origin/main
        after
        """
    )

    let prepared = RepositoryMergeConflictDraftPolicy.preparedText(
      for: .manualMerge,
      conflict: conflict
    )

    XCTAssertEqual(prepared, "before\nlocal\nremote\nafter")
    XCTAssertFalse(prepared?.contains("<<<<<<<") == true)
    XCTAssertFalse(prepared?.contains("=======") == true)
    XCTAssertFalse(prepared?.contains(">>>>>>>") == true)
    XCTAssertFalse(prepared?.contains("old") == true)
  }

  func testMalformedMarkersNeverSeedFinalEditor() {
    let conflict = makeConflict(final: "<<<<<<< HEAD\nunterminated")

    XCTAssertEqual(
      RepositoryMergeConflictDraftPolicy.initialText(for: conflict),
      "local\n"
    )
  }

  func testMissingSideIsUnavailableInsteadOfBecomingEmptyFile() {
    let conflict = RepositoryMergeConflict(
      repositoryPath: "content/post.md",
      base: .text("base\n"),
      ours: .missing(),
      theirs: .text("remote\n"),
      final: .text("remote\n")
    )

    XCTAssertNil(
      RepositoryMergeConflictDraftPolicy.preparedText(for: .ours, conflict: conflict)
    )
    XCTAssertEqual(
      RepositoryMergeConflictDraftPolicy.preparedText(for: .theirs, conflict: conflict),
      "remote\n"
    )
  }

  private func makeConflict(final: String) -> RepositoryMergeConflict {
    RepositoryMergeConflict(
      repositoryPath: "content/post.md",
      base: .text("base\n"),
      ours: .text("local\n"),
      theirs: .text("remote\n"),
      final: .text(final)
    )
  }
}
