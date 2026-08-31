import Foundation
import XCTest

@testable import PersonalSitePublisherMac

final class SettingsSinglePageContentTests: XCTestCase {
  func testEverySettingsPageDeclaresEachSubsectionAnchorExactlyOnce() throws {
    let pageTabs: [(String, SettingsTab)] = [
      ("SettingsConfigurationStatusView.swift", .configurationStatus),
      ("DefaultRuleSettingsView.swift", .defaultRules),
      ("TokenSettingsView.swift", .token),
      ("AISettingsView.swift", .ai),
      ("DataManagementView.swift", .dataManagement),
      ("AppearanceSettingsView.swift", .appearance),
      ("EditorSettingsView.swift", .editor),
      ("RSSMaintenanceSettingsView.swift", .rss),
      ("PrivacySettingsView.swift", .privacy),
    ]

    for (file, tab) in pageTabs {
      let source = try source(for: file)
      for subsection in SettingsSubsection.sections(for: tab) {
        let anchor = "SettingsSubsectionAnchor(subsection: .\(subsection.rawValue))"
        XCTAssertEqual(
          source.components(separatedBy: anchor).count - 1,
          1,
          "\(file) must declare \(anchor) exactly once"
        )
      }
    }
  }

  func testOwnedSettingsPagesHideLocalScrollIndicators() throws {
    let files = [
      "SettingsConfigurationStatusView.swift",
      "DefaultRuleSettingsView.swift",
      "TokenSettingsView.swift",
      "AISettingsView.swift",
      "AppearanceSettingsView.swift",
      "EditorSettingsView.swift",
      "RSSMaintenanceSettingsView.swift",
      "PrivacySettingsView.swift",
      "DataManagementView.swift",
      "AIWritingStyleSection.swift",
      "AIProviderSection.swift",
    ]

    for file in files {
      let source = try source(for: file)
      XCTAssertFalse(source.contains("scrollIndicators(.automatic)"), file)
      XCTAssertFalse(source.contains("showsIndicators: true"), file)
    }
  }

  private func source(for file: String) throws -> String {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let sourceURL = repositoryRoot.appendingPathComponent(
      "Sources/PersonalSitePublisherMac/Views/Settings/\(file)"
    )
    return try String(contentsOf: sourceURL, encoding: .utf8)
  }
}
