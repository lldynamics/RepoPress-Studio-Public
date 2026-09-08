import XCTest

@testable import PersonalSitePublisherMac

final class SettingsSearchSessionTests: XCTestCase {
  func testOpeningAndReturningToResultsPreservesTheOriginalQuery() throws {
    var session = SettingsSearchSession()
    session.updateQuery("主题")
    let result = try XCTUnwrap(SettingsSearchIndex.search(query: session.query).first)

    session.open(result)
    XCTAssertEqual(session.query, "主题")
    XCTAssertTrue(session.canReturnToResults)
    XCTAssertEqual(session.sidebarQuery, "")
    XCTAssertEqual(session.highlight?.subsection, .appearanceTheme)

    // Browsing another page dismisses the cue without losing the way back.
    session.dismissHighlight()
    XCTAssertTrue(session.canReturnToResults)
    session.showResults()
    XCTAssertEqual(session.sidebarQuery, "主题")
    XCTAssertFalse(session.canReturnToResults)
    XCTAssertNil(session.highlight)
    XCTAssertTrue(SettingsSearchIndex.search(query: session.query).contains(result))
  }

  func testEditingOrClearingTheQueryLeavesTheOpenedResultState() throws {
    var session = SettingsSearchSession()
    session.updateQuery("主题")
    session.open(try XCTUnwrap(SettingsSearchIndex.search(query: session.query).first))

    session.updateQuery("字体")
    XCTAssertEqual(session.sidebarQuery, "字体")
    XCTAssertFalse(session.canReturnToResults)
    XCTAssertNil(session.highlight)

    session.updateQuery("")
    XCTAssertEqual(session.sidebarQuery, "")
    XCTAssertFalse(session.canReturnToResults)
  }

  func testAnOlderTimeoutCannotDismissANewerSelectionOfTheSameResult() throws {
    var session = SettingsSearchSession()
    session.updateQuery("主题")
    let result = try XCTUnwrap(SettingsSearchIndex.search(query: session.query).first)
    session.open(result)
    let firstID = try XCTUnwrap(session.highlight?.id)
    session.showResults()
    session.open(result)
    let secondID = try XCTUnwrap(session.highlight?.id)

    XCTAssertNotEqual(firstID, secondID)
    session.dismissHighlight(id: firstID)
    XCTAssertEqual(session.highlight?.id, secondID)
    session.dismissHighlight(id: secondID)
    XCTAssertNil(session.highlight)
  }

  func testEveryIndexedResultHighlightsItsDestinationTab() {
    for item in SettingsSearchIndex.allItems {
      var session = SettingsSearchSession()
      session.open(item)
      XCTAssertEqual(session.highlight?.subsection.tab, item.tab, item.id)
    }
  }

  func testHighlightClipsToTheViewportAndStopsBeforeTheNextSection() {
    let highlight = SettingsSearchHighlight(subsection: .appearanceTheme)
    let frame = highlight.visibleFrame(
      anchorFrames: [
        .appearanceTheme: CGRect(x: 20, y: -40, width: 560, height: 0),
        .appearanceLanguage: CGRect(x: 20, y: 180, width: 560, height: 0),
        // A stale frame from another page must not shorten this section.
        .aiConnection: CGRect(x: 20, y: 30, width: 560, height: 0),
      ],
      viewport: CGRect(x: 0, y: 0, width: 600, height: 400)
    )
    XCTAssertEqual(frame, CGRect(x: 20, y: 0, width: 560, height: 180))
  }

  func testHighlightDoesNotDrawForMissingOrOffscreenAnchors() {
    let highlight = SettingsSearchHighlight(subsection: .appearanceTheme)
    let viewport = CGRect(x: 0, y: 0, width: 600, height: 400)
    XCTAssertNil(highlight.visibleFrame(anchorFrames: [:], viewport: viewport))
    XCTAssertNil(
      highlight.visibleFrame(
        anchorFrames: [
          .appearanceTheme: CGRect(x: 20, y: 500, width: 560, height: 0)
        ],
        viewport: viewport
      )
    )
  }
}
