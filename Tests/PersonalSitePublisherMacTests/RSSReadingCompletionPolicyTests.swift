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
}
