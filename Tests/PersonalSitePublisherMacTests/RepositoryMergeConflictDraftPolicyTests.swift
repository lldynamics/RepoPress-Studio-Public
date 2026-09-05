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

  func testManualMergeNeverConcatenatesDiff3ConflictSides() {
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

    XCTAssertNil(prepared)
    XCTAssertTrue(
      RepositoryMergeConflictPolicy.containsConflictMarkers(
        RepositoryMergeConflictDraftPolicy.initialText(for: conflict)
      )
    )
  }

  func testManualMergeAcceptsOnlyAnAlreadyMarkerFreeWorkingTreeVersion() {
    let conflict = makeConflict(final: "carefully merged\n")

    XCTAssertEqual(
      RepositoryMergeConflictDraftPolicy.preparedText(for: .manualMerge, conflict: conflict),
      "carefully merged\n"
    )
  }

  func testMalformedMarkersRemainVisibleForManualResolution() {
    let conflict = makeConflict(final: "<<<<<<< HEAD\nunterminated")

    XCTAssertEqual(
      RepositoryMergeConflictDraftPolicy.initialText(for: conflict),
      "<<<<<<< HEAD\nunterminated"
    )
  }

  func testMarkdownSetextHeadingDividerIsNotTreatedAsAConflictMarker() {
    XCTAssertFalse(
      RepositoryMergeConflictPolicy.containsConflictMarkers(
        "A valid Markdown heading\n=======\n"
      )
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
