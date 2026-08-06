import XCTest
@testable import PersonalSitePublisherMac

final class RSSReadingCompletionPolicyTests: XCTestCase {
  func testOnlyNearEndProgressAutomaticallyMarksRead() {
    XCTAssertFalse(
      RSSReadingCompletionPolicy.shouldAutomaticallyMarkRead(progress: 0.994)
    )
    XCTAssertTrue(
      RSSReadingCompletionPolicy.shouldAutomaticallyMarkRead(progress: 0.995)
    )
    XCTAssertTrue(
      RSSReadingCompletionPolicy.shouldAutomaticallyMarkRead(progress: 1)
    )
  }

  func testNonFiniteProgressNeverAutomaticallyMarksRead() {
    XCTAssertFalse(
      RSSReadingCompletionPolicy.shouldAutomaticallyMarkRead(progress: .nan)
    )
    XCTAssertFalse(
      RSSReadingCompletionPolicy.shouldAutomaticallyMarkRead(progress: .infinity)
    )
  }

  func testOnlyCrossingTheCompletionThresholdTriggersAutomaticMarking() {
    XCTAssertTrue(
      RSSReadingCompletionPolicy.didCrossCompletionThreshold(
        previousProgress: 0.994,
        progress: 0.995
      )
    )
    XCTAssertFalse(
      RSSReadingCompletionPolicy.didCrossCompletionThreshold(
        previousProgress: 0.995,
        progress: 1
      )
    )
    XCTAssertTrue(
      RSSReadingCompletionPolicy.didCrossCompletionThreshold(
        previousProgress: nil,
        progress: 1
      )
    )
  }
}
