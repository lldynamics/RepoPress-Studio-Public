import AppKit
import Foundation
import XCTest

@testable import PersonalSitePublisherMac

final class P3VisualPresentationTests: XCTestCase {
  func testPreviewForegroundChoosesReadableColorForLightAndDarkAccents() {
    XCTAssertEqual(
      AppearancePreviewContrast.foregroundColor(for: NSColor(calibratedWhite: 0.9, alpha: 1)),
      .black
    )
    XCTAssertEqual(
      AppearancePreviewContrast.foregroundColor(for: NSColor(calibratedWhite: 0.1, alpha: 1)),
      .white
    )
    XCTAssertEqual(
      AppearancePreviewContrast.foregroundColor(
        for: NSColor(srgbRed: 0.72, green: 0.40, blue: 0.0, alpha: 1)
      ),
      .black
    )
  }
}
