import XCTest

@testable import PersonalSitePublisherMac

final class WorkbenchAccentPaletteTests: XCTestCase {
  func testPaletteCasesAndStableStorageValues() {
    XCTAssertEqual(
      WorkbenchAccentPalette.allCases,
      [.system, .emerald, .blue, .violet, .amber, .rose, .graphite]
    )
    XCTAssertEqual(WorkbenchAccentPalette.storageKey, "workbenchAccentPaletteV1")
    XCTAssertEqual(WorkbenchAccentPalette.emerald.rawValue, "emerald")
  }

  func testUnknownOrMissingPreferenceFallsBackToSystem() {
    XCTAssertEqual(WorkbenchAccentPalette.resolved(rawValue: nil), .system)
    XCTAssertEqual(WorkbenchAccentPalette.resolved(rawValue: ""), .system)
    XCTAssertEqual(WorkbenchAccentPalette.resolved(rawValue: "unknown"), .system)
    XCTAssertEqual(WorkbenchAccentPalette.resolved(rawValue: "violet"), .violet)
  }

  func testSelectedPaletteReadsTheProvidedDefaultsSuite() throws {
    let suiteName = "WorkbenchAccentPaletteTests-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    XCTAssertEqual(WorkbenchAccentPalette.selected(in: defaults), .system)
    defaults.set(WorkbenchAccentPalette.rose.rawValue, forKey: WorkbenchAccentPalette.storageKey)
    XCTAssertEqual(WorkbenchAccentPalette.selected(in: defaults), .rose)
  }
}
