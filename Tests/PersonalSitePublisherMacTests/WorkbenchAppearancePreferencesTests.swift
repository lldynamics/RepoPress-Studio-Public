import XCTest

@testable import PersonalSitePublisherMac

final class WorkbenchAppearancePreferencesTests: XCTestCase {
  func testAppearanceModeUsesStableValuesAndFallsBackToSystem() {
    XCTAssertEqual(WorkbenchAppearanceMode.allCases, [.system, .light, .dark])
    XCTAssertEqual(WorkbenchAppearanceMode.resolved(rawValue: nil), .system)
    XCTAssertEqual(WorkbenchAppearanceMode.resolved(rawValue: "unknown"), .system)
    XCTAssertEqual(WorkbenchAppearanceMode.resolved(rawValue: "dark"), .dark)
    XCTAssertNil(WorkbenchAppearanceMode.system.colorScheme)
    XCTAssertEqual(WorkbenchAppearanceMode.light.colorScheme, .light)
    XCTAssertEqual(WorkbenchAppearanceMode.dark.colorScheme, .dark)
  }

  func testInterfaceDensityDefaultsToComfortable() {
    XCTAssertEqual(WorkbenchInterfaceDensity.allCases, [.comfortable, .compact])
    XCTAssertEqual(WorkbenchInterfaceDensity.resolved(rawValue: nil), .comfortable)
    XCTAssertEqual(WorkbenchInterfaceDensity.resolved(rawValue: "unknown"), .comfortable)
    XCTAssertEqual(WorkbenchInterfaceDensity.resolved(rawValue: "compact"), .compact)
    XCTAssertEqual(WorkbenchInterfaceDensity.comfortable.controlSize, .regular)
    XCTAssertEqual(WorkbenchInterfaceDensity.compact.controlSize, .small)
  }

  func testTextScalePreferenceUsesStableValuesAndFallsBackToStandard() {
    XCTAssertEqual(
      WorkbenchTextScalePreference.allCases,
      [.standard, .large, .extraLarge, .largest]
    )
    XCTAssertEqual(WorkbenchTextScalePreference.storageKey, "workbenchTextScaleV1")
    XCTAssertEqual(WorkbenchTextScalePreference.resolved(rawValue: nil), .standard)
    XCTAssertEqual(WorkbenchTextScalePreference.resolved(rawValue: "unknown"), .standard)
    XCTAssertEqual(WorkbenchTextScalePreference.resolved(rawValue: "extraLarge"), .extraLarge)
    XCTAssertEqual(WorkbenchTextScalePreference.standard.scale, 1)
    XCTAssertEqual(WorkbenchTextScalePreference.large.scale, 1.15)
    XCTAssertEqual(WorkbenchTextScalePreference.extraLarge.scale, 1.3)
    XCTAssertEqual(WorkbenchTextScalePreference.largest.scale, 1.5)
  }
}
