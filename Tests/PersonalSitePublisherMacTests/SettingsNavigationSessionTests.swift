import XCTest

@testable import PersonalSitePublisherMac

final class SettingsNavigationSessionTests: XCTestCase {
  func testInitialDeepLinkHasAPendingScrollBeforeThePageAppears() {
    let session = SettingsNavigationSession(selectedRoute: .subsection(.appearanceDefaults))
    XCTAssertEqual(session.selectedRoute.tab, .editor)
    XCTAssertEqual(session.detailScrollRequest?.subsection, .appearanceDefaults)
  }

  func testActiveDestinationNavigationCreatesANewScrollRequestAndCrossPageTransition() throws {
    var session = SettingsNavigationSession(selectedRoute: .subsection(.appearanceTheme))

    let selection = session.selectDestination(.token(.repository), healthDestination: nil)

    XCTAssertEqual(session.selectedRoute, .subsection(.tokenRepository))
    XCTAssertEqual(session.navigationDestination, .token(.repository))
    XCTAssertNil(session.healthDestination)
    XCTAssertTrue(selection.clearsSubsectionAnchors)
    XCTAssertTrue(selection.dismissesSearchHighlight)
    XCTAssertEqual(session.detailScrollRequest?.subsection, .tokenRepository)
  }

  func testSidebarSelectionClearsConsumedFocusAndRepeatingSubsectionCreatesANewRequest() throws {
    var session = SettingsNavigationSession(selectedRoute: .subsection(.tokenRepository))
    _ = session.selectDestination(
      .token(.repository),
      healthDestination: .repositoryToken
    )
    let firstScrollRequestID = try XCTUnwrap(session.detailScrollRequest?.id)
    let firstNavigationRequestID = session.navigationRequestID
    let firstHealthRequestID = session.healthNavigationRequestID

    let selection = session.selectSidebarRoute(.subsection(.tokenRepository))

    XCTAssertNil(session.navigationDestination)
    XCTAssertNil(session.healthDestination)
    XCTAssertNotEqual(session.navigationRequestID, firstNavigationRequestID)
    XCTAssertNotEqual(session.healthNavigationRequestID, firstHealthRequestID)
    XCTAssertNotEqual(session.detailScrollRequest?.id, firstScrollRequestID)
    XCTAssertEqual(session.detailScrollRequest?.subsection, .tokenRepository)
    XCTAssertFalse(selection.clearsSubsectionAnchors)
    XCTAssertTrue(selection.dismissesSearchHighlight)
  }

  func testRepeatingADeepLinkInTheOpenWindowRefreshesFocusAndScroll() {
    var session = SettingsNavigationSession(selectedRoute: .tab(.appearance))
    _ = session.selectDestination(.ai(.credentials), healthDestination: .aiKey)
    let previousNavigationID = session.navigationRequestID
    let previousHealthID = session.healthNavigationRequestID
    let previousScrollID = session.detailScrollRequest?.id

    let selection = session.selectDestination(.ai(.credentials), healthDestination: .aiKey)

    XCTAssertEqual(session.navigationDestination, .ai(.credentials))
    XCTAssertNotEqual(session.navigationRequestID, previousNavigationID)
    XCTAssertNotEqual(session.healthNavigationRequestID, previousHealthID)
    XCTAssertNotEqual(session.detailScrollRequest?.id, previousScrollID)
    XCTAssertFalse(selection.clearsSubsectionAnchors)
    XCTAssertTrue(selection.dismissesSearchHighlight)
  }

  func testManualScrollSynchronizesRouteWithoutReplacingPendingRequests() throws {
    var session = SettingsNavigationSession(selectedRoute: .subsection(.tokenRepository))
    _ = session.selectDestination(.token(.repository), healthDestination: nil)
    let navigationRequestID = session.navigationRequestID
    let healthNavigationRequestID = session.healthNavigationRequestID
    let detailScrollRequestID = try XCTUnwrap(session.detailScrollRequest?.id)

    XCTAssertTrue(session.synchronizeManuallyScrolledSubsection(.tokenDeployment))
    XCTAssertEqual(session.selectedRoute, .subsection(.tokenDeployment))
    XCTAssertEqual(session.navigationRequestID, navigationRequestID)
    XCTAssertEqual(session.healthNavigationRequestID, healthNavigationRequestID)
    XCTAssertEqual(session.detailScrollRequest?.id, detailScrollRequestID)
    XCTAssertFalse(session.synchronizeManuallyScrolledSubsection(.tokenDeployment))
  }

  func testStaleGeometryCannotNavigateBackToThePreviousPage() {
    var session = SettingsNavigationSession(selectedRoute: .tab(.ai))
    _ = session.selectSidebarRoute(.tab(.siteAI))

    XCTAssertFalse(session.synchronizeManuallyScrolledSubsection(.aiAdvanced))
    XCTAssertEqual(session.selectedRoute, .tab(.siteAI))
    XCTAssertEqual(session.detailScrollRequest?.subsection, .aiSiteConnection)
  }
}
