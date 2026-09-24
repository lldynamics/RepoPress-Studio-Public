import XCTest

@testable import PersonalSitePublisherMac

final class SettingsSubsectionNavigationTests: XCTestCase {
  func testOverviewOpensAtTaskShortcutsWhileHealthSearchTargetsReadiness() {
    XCTAssertEqual(
      SettingsSubsection.sections(for: .configurationStatus),
      [.configurationTasks, .configurationReadiness]
    )
    XCTAssertEqual(SettingsRoute.tab(.configurationStatus).subsection, .configurationTasks)
    XCTAssertEqual(
      SettingsSubsection.section(forSearchItemID: "status.health"),
      .configurationReadiness
    )
  }

  func testEverySettingsTabHasAtLeastOneFocusedSubsection() {
    for tab in SettingsTab.allCases {
      let sections = SettingsSubsection.sections(for: tab)
      XCTAssertFalse(sections.isEmpty, "Missing subsection for \(tab.id)")
      XCTAssertTrue(sections.allSatisfy { $0.tab == tab })
      XCTAssertEqual(SettingsSubsection.defaultSection(for: tab), sections.first)
    }
  }

  func testSiteSettingsTabsExposeStableSubsections() {
    XCTAssertEqual(
      SettingsSubsection.sections(for: .defaultRules),
      [.rulesBasics, .rulesDiscovery, .rulesFrontMatter, .rulesPaths]
    )
    XCTAssertEqual(
      SettingsSubsection.sections(for: .token),
      [.tokenRepository, .tokenDeployment, .tokenAnalytics]
    )
    XCTAssertEqual(
      SettingsSubsection.sections(for: .ai),
      [.aiConnection, .aiAdvanced]
    )
  }

  func testMovedSettingsRetainTheirLegacyEntryPoints() {
    XCTAssertEqual(
      SettingsSubsection.sections(for: .siteAI), [.aiSiteConnection, .aiWritingStyle]
    )
    XCTAssertEqual(SettingsRoute.requestedID("ai.writingStyle"), .subsection(.aiWritingStyle))
    XCTAssertEqual(SettingsRoute.requestedID("ai.writingStyle")?.tab, .siteAI)
    XCTAssertEqual(
      SettingsRoute.requestedID("appearance.defaults"), .subsection(.appearanceDefaults))
    XCTAssertEqual(SettingsRoute.requestedID("appearance.defaults")?.tab, .editor)
    XCTAssertEqual(
      SettingsRoute.workspace(destination: .tab(.appearance), subsection: .appearanceDefaults),
      .subsection(.appearanceDefaults)
    )
    XCTAssertEqual(
      SettingsRoute.workspace(destination: .tab(.ai), subsection: .aiWritingStyle),
      .subsection(.aiWritingStyle)
    )
  }

  func testStructuredDestinationsCoverEveryDeepLinkRoute() {
    let routes: [(SettingsDestination, SettingsSubsection)] = [
      (.rules(.paths), .rulesPaths),
      (.token(.repository), .tokenRepository),
      (.token(.deployment), .tokenDeployment),
      (.token(.analytics), .tokenAnalytics),
      (.ai(.connection), .aiConnection),
      (.ai(.credentials), .aiConnection),
      (.ai(.writingStyle), .aiWritingStyle),
      (.data(.drafts), .dataDrafts),
      (.data(.backup), .dataBackup),
      (.data(.migration), .dataMigration),
    ]

    for (destination, subsection) in routes {
      XCTAssertEqual(SettingsSubsection.section(for: destination), subsection)
      XCTAssertEqual(subsection.tab, destination.tab)
    }
  }

  func testLegacyRequestedIDsResolveToTheirExactVisibleSubsections() {
    XCTAssertEqual(SettingsRoute.requestedID("language"), .subsection(.appearanceLanguage))
    XCTAssertEqual(SettingsRoute.requestedID("storage"), .subsection(.dataStorage))
    XCTAssertEqual(SettingsRoute.requestedID("data"), .tab(.dataManagement))
    XCTAssertEqual(
      SettingsRoute.restored(lastViewedID: "language"), .subsection(.appearanceLanguage))
    XCTAssertEqual(SettingsRoute.restored(lastViewedID: "storage"), .subsection(.dataStorage))
  }

  func testRestoredRouteFallsBackToOverviewForMissingOrUnknownIDs() {
    XCTAssertEqual(SettingsRoute.restored(lastViewedID: nil), .tab(.configurationStatus))
    XCTAssertEqual(SettingsRoute.restored(lastViewedID: ""), .tab(.configurationStatus))
    XCTAssertEqual(SettingsRoute.restored(lastViewedID: "removed-tab"), .tab(.configurationStatus))
  }

  func testWorkspaceSubsectionControlsDisplayWithoutDiscardingCompatibleDestination() {
    XCTAssertEqual(
      SettingsRoute.workspace(
        destination: .tab(.appearance),
        subsection: .appearanceTheme
      ),
      .subsection(.appearanceTheme)
    )
    XCTAssertEqual(
      SettingsRoute.workspace(
        destination: .ai(.credentials),
        subsection: .aiConnection
      ),
      .subsection(.aiConnection)
    )
    XCTAssertEqual(
      SettingsRoute.workspace(
        destination: .ai(.credentials),
        subsection: .appearanceTheme
      ),
      .subsection(.aiConnection)
    )
  }

  func testGlobalSearchRoutesToFocusedSubsections() {
    let routes: [String: SettingsSubsection] = [
      "status.repo": .configurationReadiness,
      "status.health": .configurationReadiness,
      "rules.site": .rulesBasics,
      "rules.discovery": .rulesDiscovery,
      "rules.frontMatter": .rulesFrontMatter,
      "rules.paths": .rulesPaths,
      "token.repository": .tokenRepository,
      "token.deployment": .tokenDeployment,
      "token.analytics": .tokenAnalytics,
      "ai.provider": .aiConnection,
      "ai.credentials": .aiConnection,
      "ai.advanced": .aiAdvanced,
      "ai.siteConnection": .aiSiteConnection,
      "ai.writingStyle": .aiWritingStyle,
      "data.drafts": .dataDrafts,
      "data.storage": .dataStorage,
      "data.backup": .dataBackup,
      "data.migration": .dataMigration,
      "appearance.launch": .appearanceBehavior,
      "appearance.theme": .appearanceTheme,
      "appearance.language": .appearanceLanguage,
      "appearance.defaults": .appearanceDefaults,
      "editor.preview": .editorPreview,
      "editor.typography": .editorTypography,
      "editor.comfort": .editorAssistance,
      "editor.tools": .editorAutomation,
      "rss.refresh": .rssRefresh,
      "rss.translation": .rssReading,
      "rss.storage": .rssOfflineNetwork,
      "rss.opml": .rssMigration,
      "rss.maintenance": .rssCleanup,
      "privacy.quickHide": .privacyQuickHide,
      "privacy.masking": .privacyMasking,
      "privacy.status": .privacyStatus,
    ]

    for (itemID, subsection) in routes {
      XCTAssertEqual(SettingsSubsection.section(forSearchItemID: itemID), subsection)
    }

    XCTAssertEqual(Set(routes.keys), Set(SettingsSearchIndex.allItems.map(\.id)))
    for item in SettingsSearchIndex.allItems {
      let subsection = SettingsSubsection.section(forSearchItemID: item.id)
      XCTAssertNotNil(subsection, "Missing subsection for search item \(item.id)")
      XCTAssertEqual(subsection?.tab, item.tab)
    }
  }
}
