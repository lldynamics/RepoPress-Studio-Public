import XCTest
@testable import PersonalSitePublisherMac

final class MarkdownWritingGoalStatusBarTests: XCTestCase {
  func testProgressUsesCurrentCountAgainstGoal() {
    let progress = MarkdownWritingGoalProgress(currentCount: 1_820, goal: 2_500)

    XCTAssertEqual(progress.fraction, 0.728, accuracy: 0.0001)
    XCTAssertEqual(progress.percentage, 72)
    XCTAssertFalse(progress.isComplete)
  }

  func testProgressClampsToFullWhenGoalIsReached() {
    let progress = MarkdownWritingGoalProgress(currentCount: 2_600, goal: 2_500)

    XCTAssertEqual(progress.fraction, 1)
    XCTAssertEqual(progress.percentage, 100)
    XCTAssertTrue(progress.isComplete)
  }

  func testInvalidGoalDoesNotProduceProgress() {
    let progress = MarkdownWritingGoalProgress(currentCount: 500, goal: 0)

    XCTAssertEqual(progress.fraction, 0)
    XCTAssertEqual(progress.percentage, 0)
    XCTAssertFalse(progress.isComplete)
  }
}
