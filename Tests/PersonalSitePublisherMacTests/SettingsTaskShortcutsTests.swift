import Testing

@testable import PersonalSitePublisherMac

struct SettingsTaskShortcutsTests {
  @Test
  func shortcutsUseStableSettingsDestinations() {
    let destinations = SettingsTaskShortcut.allCases.map(\.destination)

    #expect(
      destinations == [
        .rules(.paths),
        .ai(.connection),
        .tab(.editor),
        .data(.backup),
      ])
  }

  @Test
  func shortcutIDsFollowDestinationIDs() {
    for shortcut in SettingsTaskShortcut.allCases {
      #expect(shortcut.id == shortcut.destination.id)
    }
  }

  @Test
  func shortcutsShowTheDestinationScope() {
    #expect(SettingsTaskShortcut.publishing.scopePresentation == .currentSite)
    #expect(SettingsTaskShortcut.aiConnection.scopePresentation == .sharedConnection)
    #expect(SettingsTaskShortcut.editor.scopePresentation == .shared)
    #expect(SettingsTaskShortcut.backup.scopePresentation == .shared)
  }
}
