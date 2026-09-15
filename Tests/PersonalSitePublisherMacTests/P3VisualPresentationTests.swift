import AppKit
import Foundation
import XCTest

@testable import PersonalSitePublisherMac

final class P3VisualPresentationTests: XCTestCase {
  func testNeutralScrollbarsDoNotUseRedSemanticColorOrCSS() {
    XCTAssertFalse(ThinRedScrollbarWebStyle.css.contains("systemRed"))
    XCTAssertFalse(ThinRedScrollbarWebStyle.css.contains("255, 59, 48"))
    XCTAssertFalse(ThinRedScrollbarWebStyle.css.contains("255, 69, 58"))
    XCTAssertTrue(ThinRedScrollbarWebStyle.css.contains("127, 127, 127"))
    XCTAssertTrue(ThinRedScrollbarWebStyle.css.contains("prefers-color-scheme: dark"))
    XCTAssertFalse(ThinRedScrollbarWebStyle.injectionSource.contains("thin-red-scrollbar-style"))
  }

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
