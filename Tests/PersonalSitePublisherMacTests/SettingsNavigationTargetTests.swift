import XCTest

@testable import PersonalSitePublisherMac

final class SettingsNavigationTargetTests: XCTestCase {
  func testRequestedIDsKeepExistingRoutesAndHealthFocus() {
    let paths = SettingsNavigationTarget.requestedID(
      "rules.paths",
      shouldOpenAIKeyConnection: { false }
    )
    XCTAssertEqual(paths?.destination, .rules(.paths))
    XCTAssertEqual(paths?.route, .subsection(.rulesPaths))
    XCTAssertEqual(paths?.healthDestination, .defaultRules)

    let token = SettingsNavigationTarget.requestedID(
      "token.repository",
      shouldOpenAIKeyConnection: { false }
    )
    XCTAssertEqual(token?.destination, .token(.repository))
    XCTAssertEqual(token?.route, .subsection(.tokenRepository))
    XCTAssertEqual(token?.healthDestination, .repositoryToken)

    let language = SettingsNavigationTarget.requestedID(
      "language",
      shouldOpenAIKeyConnection: { false }
    )
    XCTAssertEqual(language?.destination, .tab(.appearance))
    XCTAssertEqual(language?.route, .subsection(.appearanceLanguage))
  }

  func testAIKeyCompatibilityOnlyRedirectsWhenKeyIsMissing() {
    let missingKey = SettingsNavigationTarget.requestedID(
      "ai.credentials",
      shouldOpenAIKeyConnection: { true }
    )
    XCTAssertEqual(missingKey?.destination, .ai(.connection))
    XCTAssertEqual(missingKey?.route, .subsection(.aiConnection))
    XCTAssertEqual(missingKey?.healthDestination, .aiKey)

    let existingKey = SettingsNavigationTarget.requestedID(
      "ai.credentials",
      shouldOpenAIKeyConnection: { false }
    )
    XCTAssertEqual(existingKey?.destination, .ai(.credentials))
    XCTAssertEqual(existingKey?.route, .subsection(.aiConnection))
    XCTAssertNil(existingKey?.healthDestination)
  }

  func testNonAICredentialsAndUnknownIDsDoNotInspectAIState() {
    var connectionChecks = 0
    let checkConnection = {
      connectionChecks += 1
      return true
    }
    XCTAssertNil(
      SettingsNavigationTarget.requestedID(
        "unknown-route",
        shouldOpenAIKeyConnection: checkConnection
      )
    )
    XCTAssertEqual(
      SettingsNavigationTarget.requestedID(
        "data.backup",
        shouldOpenAIKeyConnection: checkConnection
      )?.route,
      .subsection(.dataBackup)
    )
    XCTAssertEqual(connectionChecks, 0)
  }

  func testMovedSearchResultsAndRequestsAgreeOnTheirNewPage() throws {
    for id in ["appearance.defaults", "ai.writingStyle"] {
      let item = try XCTUnwrap(SettingsSearchIndex.allItems.first { $0.id == id })
      let searchTarget = SettingsNavigationTarget.searchItem(item)
      let requestTarget = try XCTUnwrap(
        SettingsNavigationTarget.requestedID(id, shouldOpenAIKeyConnection: { false })
      )
      XCTAssertEqual(searchTarget.route, requestTarget.route)
      XCTAssertEqual(searchTarget.destination.tab, searchTarget.route.tab)
      XCTAssertEqual(requestTarget.destination.tab, requestTarget.route.tab)
    }
  }

  func testSearchResultUsesItsFocusedSubsection() throws {
    let item = try XCTUnwrap(
      SettingsSearchIndex.allItems.first(where: { $0.id == "data.backup" })
    )
    let target = SettingsNavigationTarget.searchItem(item)
    XCTAssertEqual(target.destination, .data(.backup))
    XCTAssertEqual(target.route, .subsection(.dataBackup))
    XCTAssertNil(target.healthDestination)
  }
}
