import CoreGraphics
import XCTest
@testable import PersonalSitePublisherMac

final class KnowledgeImageViewportPolicyTests: XCTestCase {
  func testZoomIsBoundedToHalfThroughFourTimes() {
    XCTAssertEqual(KnowledgeImageViewportPolicy.clampedZoom(0.1), 0.5)
    XCTAssertEqual(KnowledgeImageViewportPolicy.clampedZoom(2), 2)
    XCTAssertEqual(KnowledgeImageViewportPolicy.clampedZoom(9), 4)
  }

  func testLandscapeAndPortraitContentExceedsViewportAtMaximumZoom() {
    let viewport = CGSize(width: 400, height: 300)
    let landscape = KnowledgeImageViewportPolicy.contentSize(
      imageSize: CGSize(width: 1600, height: 900), viewportSize: viewport, zoom: 4)
    let portrait = KnowledgeImageViewportPolicy.contentSize(
      imageSize: CGSize(width: 900, height: 1600), viewportSize: viewport, zoom: 4)
    XCTAssertGreaterThan(landscape.width, viewport.width)
    XCTAssertGreaterThan(landscape.height, viewport.height)
    XCTAssertGreaterThan(portrait.width, viewport.width)
    XCTAssertGreaterThan(portrait.height, viewport.height)
  }
}
