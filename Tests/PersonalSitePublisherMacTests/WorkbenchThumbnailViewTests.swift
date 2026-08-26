import CoreGraphics
import QuickLookThumbnailing
import XCTest
@testable import PersonalSitePublisherMac

final class WorkbenchThumbnailViewTests: XCTestCase {
  func testRequestConvertsPixelBudgetToDisplayPoints() {
    let request = WorkbenchThumbnailRequest(
      fileURL: URL(fileURLWithPath: "/tmp/example.png"),
      maxPixelSize: 512,
      displayScale: 2
    )

    XCTAssertEqual(request.quickLookRequest.size, CGSize(width: 256, height: 256))
    XCTAssertEqual(request.quickLookRequest.scale, 2)
    XCTAssertEqual(request.quickLookRequest.representationTypes, .thumbnail)
  }

  func testRequestClampsPixelBudget() {
    let tooSmall = WorkbenchThumbnailRequest(
      fileURL: URL(fileURLWithPath: "/tmp/small.png"),
      maxPixelSize: 0,
      displayScale: 1
    )
    let tooLarge = WorkbenchThumbnailRequest(
      fileURL: URL(fileURLWithPath: "/tmp/large.png"),
      maxPixelSize: 8_192,
      displayScale: 1
    )

    XCTAssertEqual(tooSmall.quickLookRequest.size, CGSize(width: 1, height: 1))
    XCTAssertEqual(tooLarge.quickLookRequest.size, CGSize(width: 4_096, height: 4_096))
  }

  func testRequestFallsBackToUnitScaleForInvalidDisplayScale() {
    let request = WorkbenchThumbnailRequest(
      fileURL: URL(fileURLWithPath: "/tmp/example.png"),
      maxPixelSize: 128,
      displayScale: .nan
    )

    XCTAssertEqual(request.quickLookRequest.scale, 1)
    XCTAssertEqual(request.quickLookRequest.size, CGSize(width: 128, height: 128))
  }
}
