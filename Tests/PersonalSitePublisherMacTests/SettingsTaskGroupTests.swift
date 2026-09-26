import XCTest

@testable import PersonalSitePublisherMac

final class SettingsTaskGroupTests: XCTestCase {
  func testEverySettingsTabAppearsInExactlyOneTaskGroup() {
    let groupedTabs = SettingsTaskGroup.allCases.flatMap(\.tabs)

    XCTAssertEqual(Set(groupedTabs), Set(SettingsTab.allCases))
    XCTAssertEqual(groupedTabs.count, SettingsTab.allCases.count)
  }

  func testScopeGroupsKeepTheExpectedNavigationOrder() {
    XCTAssertEqual(SettingsTaskGroup.allCases, [.application, .currentSite])
    XCTAssertEqual(
      SettingsTaskGroup.application.tabs,
      [.appearance, .editor, .ai, .rss, .dataManagement, .privacy]
    )
    XCTAssertEqual(
      SettingsTaskGroup.currentSite.tabs,
      [.configurationStatus, .defaultRules, .token, .siteAI]
    )
    XCTAssertTrue(SettingsTaskGroup.application.tabs.allSatisfy { !$0.isSiteScoped })
    XCTAssertTrue(SettingsTaskGroup.currentSite.tabs.allSatisfy(\.isSiteScoped))
  }

  func testAppPreferencesOpenInTheSettingsWindowAndSiteSettingsStayInline() {
    XCTAssertTrue(SettingsNavigation.opensInSettingsWindow(nil))
    for tab in SettingsTaskGroup.application.tabs {
      XCTAssertTrue(SettingsNavigation.opensInSettingsWindow(.tab(tab)), "\(tab)")
    }
    for tab in SettingsTaskGroup.currentSite.tabs {
      XCTAssertFalse(SettingsNavigation.opensInSettingsWindow(.tab(tab)), "\(tab)")
    }
    XCTAssertTrue(SettingsNavigation.opensInSettingsWindow(.ai(.connection)))
    XCTAssertFalse(SettingsNavigation.opensInSettingsWindow(.ai(.writingStyle)))
    XCTAssertFalse(SettingsNavigation.opensInSettingsWindow(.token(.repository)))
  }

  func testEachTabResolvesBackToItsTaskGroup() {
    for group in SettingsTaskGroup.allCases {
      for tab in group.tabs {
        XCTAssertEqual(SettingsTaskGroup.group(for: tab), group)
      }
    }
  }
}
