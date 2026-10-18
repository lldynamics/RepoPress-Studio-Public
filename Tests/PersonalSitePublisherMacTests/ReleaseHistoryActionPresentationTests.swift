import Foundation
import XCTest

@testable import PersonalSitePublisherMac

final class ReleaseHistoryActionPresentationTests: XCTestCase {
  func testPrimaryActionFollowsPriorityForEveryAvailabilityCombination() {
    let priority: [ReleaseHistoryActionPresentation] = [
      .resumeReview,
      .recheckDeployment,
      .openRemote,
      .copyCommand,
      .copyRecovery,
    ]

    for combination in 0..<32 {
      let available = (0..<priority.count).map { combination & (1 << $0) != 0 }
      let expected = priority.indices.first(where: { available[$0] }).map { priority[$0] }
      let actual = ReleaseHistoryActionPresentation.primaryAction(
        canResumeReview: available[0],
        canRecheckDeployment: available[1],
        canOpenRemote: available[2],
        canCopyCommand: available[3],
        canCopyRecovery: available[4]
      )

      XCTAssertEqual(actual, expected, "Availability combination: \(combination)")
      XCTAssertEqual(priority.filter { $0 == actual }.count, combination == 0 ? 0 : 1)
    }
  }

  func testOperationalContextWidthPreservesMinimum() {
    let availableWidths: [CGFloat] = [0, 800, 1_080, 1_100]
    for availableWidth in availableWidths {
      XCTAssertEqual(
        WorkbenchPageMetrics.operationalContextWidth(forAvailableWidth: availableWidth),
        WorkbenchPageMetrics.operationalContextWidth
      )
    }
  }

  func testOperationalContextWidthScalesBetweenBounds() {
    XCTAssertEqual(
      WorkbenchPageMetrics.operationalContextWidth(forAvailableWidth: 1_200),
      336,
      accuracy: 0.001
    )
    XCTAssertEqual(
      WorkbenchPageMetrics.operationalContextWidth(forAvailableWidth: 1_400),
      392,
      accuracy: 0.001
    )
  }

  func testOperationalContextWidthCapsWidePages() {
    let availableWidths: [CGFloat] = [1_600, 2_400, 4_000]
    for availableWidth in availableWidths {
      XCTAssertEqual(
        WorkbenchPageMetrics.operationalContextWidth(forAvailableWidth: availableWidth),
        440
      )
    }
  }

  func testOperationalSplitThresholdRemainsUnchanged() {
    let threshold = WorkbenchPageMetrics.operationalSplitMinimumWidth
    XCTAssertFalse(WorkbenchPageMetrics.usesOperationalSplit(for: threshold - 1))
    XCTAssertTrue(WorkbenchPageMetrics.usesOperationalSplit(for: threshold))
  }
}
