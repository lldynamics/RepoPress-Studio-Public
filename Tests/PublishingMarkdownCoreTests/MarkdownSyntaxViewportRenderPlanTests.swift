import Foundation
@testable import PublishingMarkdownCore
import XCTest

final class MarkdownSyntaxViewportRenderPlanTests: XCTestCase {
  func testInitialViewportAppliesTheWholeCurrentSnapshot() {
    let current = snapshot(
      range: NSRange(location: 40, length: 18),
      runs: [
        MarkdownSyntaxHighlightRun(
          style: .heading,
          range: NSRange(location: 40, length: 8)
        ),
        MarkdownSyntaxHighlightRun(
          style: .bold,
          range: NSRange(location: 52, length: 6)
        ),
      ]
    )

    let plan = MarkdownSyntaxViewportRenderPlan.make(
      previousPaintedRange: nil,
      currentSnapshot: current,
      requiresFullRepaint: false
    )

    XCTAssertEqual(plan.removalRanges, [])
    XCTAssertEqual(plan.applicationSnapshots, [current])
    XCTAssertEqual(plan.affectedUTF16Length, current.range.length)
  }

  func testFullRepaintClearsPreviousViewportAndAppliesWholeCurrentSnapshot() {
    let previous = NSRange(location: 12, length: 20)
    let current = snapshot(range: NSRange(location: 80, length: 16))

    let plan = MarkdownSyntaxViewportRenderPlan.make(
      previousPaintedRange: previous,
      currentSnapshot: current,
      requiresFullRepaint: true
    )

    XCTAssertEqual(plan.removalRanges, [previous])
    XCTAssertEqual(plan.applicationSnapshots, [current])
    XCTAssertEqual(plan.affectedUTF16Length, previous.length + current.range.length)
  }

  func testLeftScrollRemovesOldTrailingStripAndAppliesNewLeadingStrip() {
    let previous = NSRange(location: 100, length: 80)
    let current = snapshot(
      range: NSRange(location: 60, length: 80),
      runs: [
        MarkdownSyntaxHighlightRun(
          style: .heading,
          range: NSRange(location: 60, length: 10)
        ),
        MarkdownSyntaxHighlightRun(
          style: .link,
          range: NSRange(location: 100, length: 12)
        ),
      ]
    )

    let plan = MarkdownSyntaxViewportRenderPlan.make(
      previousPaintedRange: previous,
      currentSnapshot: current,
      requiresFullRepaint: false
    )

    XCTAssertEqual(plan.removalRanges, [NSRange(location: 140, length: 40)])
    XCTAssertEqual(
      plan.applicationSnapshots.map(\.range),
      [NSRange(location: 60, length: 40)]
    )
    XCTAssertEqual(
      plan.applicationSnapshots.first?.runs,
      [
        MarkdownSyntaxHighlightRun(
          style: .heading,
          range: NSRange(location: 60, length: 10)
        )
      ]
    )
    XCTAssertEqual(plan.affectedUTF16Length, 80)
  }

  func testRightScrollRemovesOldLeadingStripAndAppliesNewTrailingStrip() {
    let previous = NSRange(location: 60, length: 80)
    let current = snapshot(
      range: NSRange(location: 100, length: 80),
      runs: [
        MarkdownSyntaxHighlightRun(
          style: .link,
          range: NSRange(location: 100, length: 12)
        ),
        MarkdownSyntaxHighlightRun(
          style: .codeBlock,
          range: NSRange(location: 160, length: 20)
        ),
      ]
    )

    let plan = MarkdownSyntaxViewportRenderPlan.make(
      previousPaintedRange: previous,
      currentSnapshot: current,
      requiresFullRepaint: false
    )

    XCTAssertEqual(plan.removalRanges, [NSRange(location: 60, length: 40)])
    XCTAssertEqual(
      plan.applicationSnapshots.map(\.range),
      [NSRange(location: 140, length: 40)]
    )
    XCTAssertEqual(
      plan.applicationSnapshots.first?.runs,
      [
        MarkdownSyntaxHighlightRun(
          style: .codeBlock,
          range: NSRange(location: 160, length: 20)
        )
      ]
    )
    XCTAssertEqual(plan.affectedUTF16Length, 80)
  }

  func testCurrentViewportInsidePreviousRemovesBothExposedStrips() {
    let previous = NSRange(location: 100, length: 100)
    let current = snapshot(range: NSRange(location: 130, length: 40))

    let plan = MarkdownSyntaxViewportRenderPlan.make(
      previousPaintedRange: previous,
      currentSnapshot: current,
      requiresFullRepaint: false
    )

    XCTAssertEqual(
      plan.removalRanges,
      [
        NSRange(location: 100, length: 30),
        NSRange(location: 170, length: 30),
      ]
    )
    XCTAssertEqual(plan.applicationSnapshots, [])
    XCTAssertEqual(plan.affectedUTF16Length, 60)
  }

  func testCurrentViewportContainingPreviousAppliesBothNewStrips() {
    let previous = NSRange(location: 130, length: 40)
    let current = snapshot(
      range: NSRange(location: 100, length: 100),
      runs: [
        MarkdownSyntaxHighlightRun(
          style: .heading,
          range: NSRange(location: 100, length: 30)
        ),
        MarkdownSyntaxHighlightRun(
          style: .bold,
          range: NSRange(location: 160, length: 30)
        ),
      ]
    )

    let plan = MarkdownSyntaxViewportRenderPlan.make(
      previousPaintedRange: previous,
      currentSnapshot: current,
      requiresFullRepaint: false
    )

    XCTAssertEqual(plan.removalRanges, [])
    XCTAssertEqual(
      plan.applicationSnapshots.map(\.range),
      [
        NSRange(location: 100, length: 30),
        NSRange(location: 170, length: 30),
      ]
    )
    XCTAssertEqual(
      plan.applicationSnapshots.map(\.runs),
      [
        [
          MarkdownSyntaxHighlightRun(
            style: .heading,
            range: NSRange(location: 100, length: 30)
          )
        ],
        [
          MarkdownSyntaxHighlightRun(
            style: .bold,
            range: NSRange(location: 170, length: 20)
          )
        ],
      ]
    )
    XCTAssertEqual(plan.affectedUTF16Length, 60)
  }

  func testDisjointViewportsReplaceTheOldRangeAndApplyTheNewRange() {
    let previous = NSRange(location: 1_024, length: 32)
    let current = snapshot(
      range: NSRange(location: 65_536, length: 48),
      runs: [
        MarkdownSyntaxHighlightRun(
          style: .inlineCode,
          range: NSRange(location: 65_540, length: 12)
        )
      ]
    )

    let plan = MarkdownSyntaxViewportRenderPlan.make(
      previousPaintedRange: previous,
      currentSnapshot: current,
      requiresFullRepaint: false
    )

    XCTAssertEqual(plan.removalRanges, [previous])
    XCTAssertEqual(plan.applicationSnapshots, [current])
    XCTAssertEqual(plan.affectedUTF16Length, 80)
  }

  func testIdenticalViewportDoesNoRenderingWork() {
    let range = NSRange(location: 12_345, length: 987)
    let current = snapshot(range: range)

    let plan = MarkdownSyntaxViewportRenderPlan.make(
      previousPaintedRange: range,
      currentSnapshot: current,
      requiresFullRepaint: false
    )

    XCTAssertEqual(plan.removalRanges, [])
    XCTAssertEqual(plan.applicationSnapshots, [])
    XCTAssertEqual(plan.affectedUTF16Length, 0)
  }

  func testInvalidAndZeroRangesDoNotProduceInvalidApplicationRanges() {
    let current = snapshot(range: NSRange(location: NSNotFound, length: 10))
    let invalidPlan = MarkdownSyntaxViewportRenderPlan.make(
      previousPaintedRange: NSRange(location: NSNotFound, length: 20),
      currentSnapshot: current,
      requiresFullRepaint: false
    )
    XCTAssertEqual(invalidPlan.removalRanges, [])
    XCTAssertEqual(invalidPlan.applicationSnapshots, [])
    XCTAssertEqual(invalidPlan.affectedUTF16Length, 0)

    let zeroPlan = MarkdownSyntaxViewportRenderPlan.make(
      previousPaintedRange: nil,
      currentSnapshot: snapshot(range: NSRange(location: 99, length: 0)),
      requiresFullRepaint: false
    )
    XCTAssertEqual(zeroPlan.removalRanges, [])
    XCTAssertEqual(zeroPlan.applicationSnapshots, [])
    XCTAssertEqual(zeroPlan.affectedUTF16Length, 0)

    let stalePaintPlan = MarkdownSyntaxViewportRenderPlan.make(
      previousPaintedRange: NSRange(location: 20, length: 10),
      currentSnapshot: snapshot(range: NSRange(location: 20, length: 0)),
      requiresFullRepaint: false
    )
    XCTAssertEqual(stalePaintPlan.removalRanges, [NSRange(location: 20, length: 10)])
    XCTAssertEqual(stalePaintPlan.applicationSnapshots, [])
    XCTAssertTrue(stalePaintPlan.removalRanges.allSatisfy { $0.length > 0 })
  }

  func testUTF16CoordinatesArePreservedAcrossDeltaPlanning() {
    let previous = NSRange(location: 4_096, length: 128)
    let current = snapshot(
      range: NSRange(location: 4_160, length: 128),
      runs: [
        MarkdownSyntaxHighlightRun(
          style: .link,
          range: NSRange(location: 4_256, length: 16)
        )
      ]
    )

    let plan = MarkdownSyntaxViewportRenderPlan.make(
      previousPaintedRange: previous,
      currentSnapshot: current,
      requiresFullRepaint: false
    )

    XCTAssertEqual(plan.removalRanges, [NSRange(location: 4_096, length: 64)])
    XCTAssertEqual(
      plan.applicationSnapshots.map(\.range),
      [NSRange(location: 4_224, length: 64)]
    )
    XCTAssertEqual(
      plan.applicationSnapshots.first?.runs,
      [
        MarkdownSyntaxHighlightRun(
          style: .link,
          range: NSRange(location: 4_256, length: 16)
        )
      ]
    )
  }

  private func snapshot(
    range: NSRange,
    runs: [MarkdownSyntaxHighlightRun] = []
  ) -> MarkdownSyntaxHighlightSnapshot {
    MarkdownSyntaxHighlightSnapshot(range: range, runs: runs)
  }
}
