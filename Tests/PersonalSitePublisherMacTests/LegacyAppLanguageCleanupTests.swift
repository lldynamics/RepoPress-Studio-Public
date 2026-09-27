import Foundation
import XCTest

@testable import PersonalSitePublisherMac

final class LegacyAppLanguageCleanupTests: XCTestCase {
  func testRestoresEarlierPerAppLanguageAndRemovesLegacyState() throws {
    let suite = "LegacyAppLanguageCleanupTests-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(["en"], forKey: "AppleLanguages")
    defaults.set("english", forKey: "appLanguagePreferenceV1")
    defaults.set(true, forKey: "appLanguageManagesAppleLanguagesV1")
    defaults.set(["fr"], forKey: "appLanguagePreviousAppleLanguagesV1")
    defaults.set(true, forKey: "appLanguageHadPreviousAppleLanguagesV1")

    LegacyAppLanguageCleanup.prepareForLaunch(defaults: defaults, processArguments: [])

    XCTAssertEqual(defaults.stringArray(forKey: "AppleLanguages"), ["fr"])
    XCTAssertNil(defaults.object(forKey: "appLanguagePreferenceV1"))
    XCTAssertNil(defaults.object(forKey: "appLanguageManagesAppleLanguagesV1"))
    XCTAssertNil(defaults.object(forKey: "appLanguagePreviousAppleLanguagesV1"))
    XCTAssertNil(defaults.object(forKey: "appLanguageHadPreviousAppleLanguagesV1"))
    LegacyAppLanguageCleanup.prepareForLaunch(defaults: defaults, processArguments: [])
    XCTAssertEqual(defaults.stringArray(forKey: "AppleLanguages"), ["fr"])
  }

  func testRemovesManagedOverrideWhenNoEarlierPerAppLanguageExisted() throws {
    let suite = "LegacyAppLanguageCleanupTests-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(["zh-Hans"], forKey: "AppleLanguages")
    defaults.set(true, forKey: "appLanguageManagesAppleLanguagesV1")
    defaults.set(false, forKey: "appLanguageHadPreviousAppleLanguagesV1")

    LegacyAppLanguageCleanup.prepareForLaunch(defaults: defaults, processArguments: [])

    XCTAssertNil(defaults.persistentDomain(forName: suite)?["AppleLanguages"])
  }

  func testPreservesLanguageChangedOutsideTheApp() throws {
    let suite = "LegacyAppLanguageCleanupTests-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(["zh-Hans"], forKey: "AppleLanguages")
    defaults.set("english", forKey: "appLanguagePreferenceV1")
    defaults.set(true, forKey: "appLanguageManagesAppleLanguagesV1")
    defaults.set(["fr"], forKey: "appLanguagePreviousAppleLanguagesV1")
    defaults.set(true, forKey: "appLanguageHadPreviousAppleLanguagesV1")

    LegacyAppLanguageCleanup.prepareForLaunch(defaults: defaults, processArguments: [])

    XCTAssertEqual(defaults.stringArray(forKey: "AppleLanguages"), ["zh-Hans"])
    XCTAssertNil(defaults.object(forKey: "appLanguageManagesAppleLanguagesV1"))
  }

  func testUnmanagedPerAppLanguageIsUntouched() throws {
    let suite = "LegacyAppLanguageCleanupTests-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(["en"], forKey: "AppleLanguages")
    defaults.set("system", forKey: "appLanguagePreferenceV1")

    LegacyAppLanguageCleanup.prepareForLaunch(defaults: defaults, processArguments: [])

    XCTAssertEqual(defaults.stringArray(forKey: "AppleLanguages"), ["en"])
    XCTAssertNil(defaults.object(forKey: "appLanguagePreferenceV1"))
  }

  func testExplicitLaunchArgumentDefersMigration() throws {
    let suite = "LegacyAppLanguageCleanupTests-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(["en"], forKey: "AppleLanguages")
    defaults.set(true, forKey: "appLanguageManagesAppleLanguagesV1")
    defaults.set(false, forKey: "appLanguageHadPreviousAppleLanguagesV1")

    LegacyAppLanguageCleanup.prepareForLaunch(
      defaults: defaults,
      processArguments: ["RepoPress Studio", "-AppleLanguages", "(en)"]
    )

    XCTAssertEqual(defaults.stringArray(forKey: "AppleLanguages"), ["en"])
    XCTAssertTrue(defaults.bool(forKey: "appLanguageManagesAppleLanguagesV1"))
    LegacyAppLanguageCleanup.prepareForLaunch(defaults: defaults, processArguments: [])
    XCTAssertNil(defaults.persistentDomain(forName: suite)?["AppleLanguages"])
  }
}
