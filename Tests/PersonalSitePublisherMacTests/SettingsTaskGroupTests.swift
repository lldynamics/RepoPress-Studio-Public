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

  func testEveryScopeOpensTheNativeWindowWithItsRequestedDestination() throws {
    let suiteName = "SettingsTaskGroupTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set(SettingsTab.editor.id, forKey: SettingsNavigation.lastViewedTabStorageKey)
    let destinations: [SettingsDestination?] =
      SettingsTab.allCases.map { .tab($0) } + [
        .rules(.paths), .token(.repository), .token(.deployment),
        .ai(.connection), .ai(.credentials), .ai(.writingStyle),
        .data(.drafts), .data(.backup), .data(.migration), nil,
      ]

    for destination in destinations {
      var openCount = 0
      SettingsNavigation.open(destination: destination, defaults: defaults) {
        openCount += 1
        XCTAssertEqual(
          defaults.string(forKey: SettingsNavigation.requestedTabStorageKey),
          destination?.id ?? ""
        )
      }
      XCTAssertEqual(openCount, 1)
      XCTAssertEqual(
        defaults.string(forKey: SettingsNavigation.lastViewedTabStorageKey),
        SettingsTab.editor.id,
        "One-shot navigation must not overwrite the user's reopening preference."
      )
    }
  }

  func testEachTabResolvesBackToItsTaskGroup() {
    for group in SettingsTaskGroup.allCases {
      for tab in group.tabs {
        XCTAssertEqual(SettingsTaskGroup.group(for: tab), group)
      }
    }
  }
}
