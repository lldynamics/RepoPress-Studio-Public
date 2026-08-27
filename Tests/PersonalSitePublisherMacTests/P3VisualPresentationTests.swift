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

  func testCalendarTodayProjectionUsesInjectedNowAcrossMidnight() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let beforeMidnight = calendar.date(from: DateComponents(
      calendar: calendar,
      timeZone: calendar.timeZone,
      year: 2025,
      month: 9,
      day: 3,
      hour: 23,
      minute: 59,
      second: 59
    ))!
    let afterMidnight = calendar.date(from: DateComponents(
      calendar: calendar,
      timeZone: calendar.timeZone,
      year: 2025,
      month: 9,
      day: 4,
      hour: 0,
      minute: 0,
      second: 1
    ))!

    XCTAssertTrue(
      MaintenanceCalendarDateProjection.isToday(
        date: beforeMidnight,
        now: beforeMidnight.addingTimeInterval(-1),
        calendar: calendar
      )
    )
    XCTAssertFalse(
      MaintenanceCalendarDateProjection.isToday(
        date: beforeMidnight,
        now: afterMidnight,
        calendar: calendar
      )
    )
    XCTAssertTrue(
      MaintenanceCalendarDateProjection.isToday(
        date: afterMidnight,
        now: afterMidnight.addingTimeInterval(1),
        calendar: calendar
      )
    )
  }
}
