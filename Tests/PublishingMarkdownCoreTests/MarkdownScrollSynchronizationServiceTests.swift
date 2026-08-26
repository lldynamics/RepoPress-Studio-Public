import XCTest
@testable import PublishingMarkdownCore

final class MarkdownScrollSynchronizationServiceTests: XCTestCase {
  func testProgressUsesScrollableLengthRatherThanFullContentLength() {
    let service = MarkdownScrollSynchronizationService()

    XCTAssertEqual(
      service.progress(contentOffset: 400, viewportLength: 200, contentLength: 1_000),
      0.5,
      accuracy: 0.000_1
    )
  }

  func testContentOffsetRoundTripsProgress() {
    let service = MarkdownScrollSynchronizationService()
    let offset = service.contentOffset(
      progress: 0.625,
      viewportLength: 300,
      contentLength: 1_500
    )

    XCTAssertEqual(offset, 750, accuracy: 0.000_1)
    XCTAssertEqual(
      service.progress(contentOffset: offset, viewportLength: 300, contentLength: 1_500),
      0.625,
      accuracy: 0.000_1
    )
  }

  func testValuesAreClampedAndNonScrollableContentStaysAtTop() {
    let service = MarkdownScrollSynchronizationService()

    XCTAssertEqual(service.contentOffset(progress: -1, viewportLength: 200, contentLength: 1_000), 0)
    XCTAssertEqual(service.contentOffset(progress: 2, viewportLength: 200, contentLength: 1_000), 800)
    XCTAssertEqual(service.progress(contentOffset: 50, viewportLength: 500, contentLength: 200), 0)
    XCTAssertEqual(service.progress(contentOffset: .infinity, viewportLength: 200, contentLength: 1_000), 0)
  }
}
