import Foundation
import XCTest

import PublishingAICore

final class AIChatStreamContinuationReconcilerTests: XCTestCase {
  func testReconcilerOnlyRemovesProvenSuffixOverlap() {
    var reconciler = AIChatStreamContinuationReconciler(
      alreadyYieldedText: "A base",
      overlapProbeCharacterCount: 8_192
    )
    XCTAssertEqual(reconciler.reconcile("A "), "")
    XCTAssertEqual(reconciler.reconcile("base + new"), " + new")

    var commonWord = AIChatStreamContinuationReconciler(
      alreadyYieldedText: "prefix word appears earlier, but ends here",
      overlapProbeCharacterCount: 8_192
    )
    XCTAssertEqual(commonWord.reconcile("word"), "")
    XCTAssertEqual(commonWord.finish(), "word")
  }

  func testCheckpointTextRemainsBoundedAndPreservesParagraphBoundaries() {
    XCTAssertEqual(
      AIChatStreamContinuationReconciler.checkpointText(
        from: "123456\n\nabcdef",
        maximumCharacterCount: 8
      ),
      "…\n\nabcdef"
    )
    XCTAssertEqual(
      AIChatStreamContinuationReconciler.checkpointText(
        from: "1234\nabcdef",
        maximumCharacterCount: 8
      ),
      "…\n\nabcdef"
    )
    XCTAssertEqual(
      AIChatStreamContinuationReconciler.checkpointText(
        from: "abcdefghij",
        maximumCharacterCount: 4
      ),
      "…ghij"
    )
    XCTAssertEqual(
      AIChatStreamContinuationReconciler.checkpointText(
        from: "short",
        maximumCharacterCount: 8
      ),
      "short"
    )
  }

  func testReconcilerRemovesSplitOverlapAndHandlesNoOverlapFinish() {
    var splitOverlap = AIChatStreamContinuationReconciler(alreadyYieldedText: "Abase")
    XCTAssertEqual(splitOverlap.reconcile("A"), "")
    XCTAssertEqual(splitOverlap.reconcile("base+new"), "+new")

    var noOverlap = AIChatStreamContinuationReconciler(alreadyYieldedText: "existing text")
    XCTAssertEqual(noOverlap.reconcile("new text"), "new text")
    XCTAssertEqual(noOverlap.finish(), "")

    var incomplete = AIChatStreamContinuationReconciler(alreadyYieldedText: "before common")
    XCTAssertEqual(incomplete.reconcile("common"), "")
    XCTAssertEqual(incomplete.finish(), "common")
  }

  func testParagraphBoundaryForcesResolutionAndRemovesOnlyLargestSuffixOverlap() {
    var reconciler = AIChatStreamContinuationReconciler(
      alreadyYieldedText: "intro\n\nold\n\n"
    )

    XCTAssertEqual(reconciler.reconcile("old\n"), "")
    XCTAssertEqual(reconciler.reconcile("\nnew"), "new")
    XCTAssertEqual(reconciler.reconcile(" continuation"), " continuation")
    XCTAssertEqual(reconciler.finish(), "")
  }

  func testReconcilerHandlesEmptyDeltasAndPostResolutionDeltas() {
    var empty = AIChatStreamContinuationReconciler(alreadyYieldedText: "already")
    XCTAssertEqual(empty.reconcile(""), "")
    XCTAssertEqual(empty.finish(), "")
    XCTAssertEqual(empty.reconcile("after finish"), "after finish")
    XCTAssertEqual(empty.finish(), "")

    var resolved = AIChatStreamContinuationReconciler(alreadyYieldedText: "old")
    XCTAssertEqual(resolved.reconcile("new"), "new")
    XCTAssertEqual(resolved.reconcile(" delta"), " delta")
    XCTAssertEqual(resolved.finish(), "")
  }

  func testReconcilerAndCheckpointUseCharacterLimitsForUnicodeAndMinimums() {
    var unicode = AIChatStreamContinuationReconciler(
      alreadyYieldedText: "前🙂",
      overlapProbeCharacterCount: 1
    )
    XCTAssertEqual(unicode.reconcile("🙂新"), "新")

    var clamped = AIChatStreamContinuationReconciler(
      alreadyYieldedText: "🙂",
      overlapProbeCharacterCount: 0
    )
    XCTAssertEqual(clamped.reconcile("🙂x"), "x")

    XCTAssertEqual(
      AIChatStreamContinuationReconciler.checkpointText(
        from: "甲乙🙂\n\n丙丁",
        maximumCharacterCount: 4
      ),
      "…\n\n丙丁"
    )
    XCTAssertEqual(
      AIChatStreamContinuationReconciler.checkpointText(
        from: "🙂🙂",
        maximumCharacterCount: 0
      ),
      "…🙂"
    )
  }
}
