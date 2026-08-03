import Foundation
import XCTest
@testable import PersonalSitePublisherMac

final class AppLanguagePreferenceTests: XCTestCase {
  func testLanguagePreferencesExposeStableLocaleIdentifiers() {
    XCTAssertEqual(
      AppLanguagePreference.allCases,
      [.system, .simplifiedChinese, .english]
    )
    XCTAssertNil(AppLanguagePreference.system.languageIdentifier)
    XCTAssertEqual(AppLanguagePreference.simplifiedChinese.languageIdentifier, "zh-Hans")
    XCTAssertEqual(AppLanguagePreference.english.languageIdentifier, "en")
  }

  func testStoredLanguageDoesNotApplyUntilLaunchPreparationRuns() throws {
    let suiteName = "AppLanguagePreferenceTests-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set(["fr"], forKey: "AppleLanguages")
    defaults.set(
      AppLanguagePreference.english.rawValue,
      forKey: AppLanguagePreference.storageKey
    )

    XCTAssertEqual(defaults.stringArray(forKey: "AppleLanguages"), ["fr"])

    AppLanguagePreference.prepareForLaunch(defaults: defaults)

    XCTAssertEqual(defaults.stringArray(forKey: "AppleLanguages"), ["en"])
  }

  func testLaunchPreparationRestoresSystemLanguageAfterCustomPreference() throws {
    let suiteName = "AppLanguagePreferenceTests-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set(["fr"], forKey: "AppleLanguages")
    AppLanguagePreference.english.applyBundleLanguage(to: defaults)
    defaults.set(
      AppLanguagePreference.system.rawValue,
      forKey: AppLanguagePreference.storageKey
    )

    AppLanguagePreference.prepareForLaunch(defaults: defaults)

    XCTAssertEqual(defaults.stringArray(forKey: "AppleLanguages"), ["fr"])
  }

  func testLaunchPreparationRespectsExplicitAppleLanguagesArgument() throws {
    let suiteName = "AppLanguagePreferenceTests-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set(["en"], forKey: "AppleLanguages")
    defaults.set(
      AppLanguagePreference.simplifiedChinese.rawValue,
      forKey: AppLanguagePreference.storageKey
    )

    AppLanguagePreference.prepareForLaunch(
      defaults: defaults,
      processArguments: ["RepoPress Studio", "-AppleLanguages", "(en)"]
    )

    XCTAssertEqual(defaults.stringArray(forKey: "AppleLanguages"), ["en"])
  }

  func testCustomLanguageRestoresExistingPerAppLanguageWhenReturningToSystem() throws {
    let suiteName = "AppLanguagePreferenceTests-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set(["fr"], forKey: "AppleLanguages")

    AppLanguagePreference.english.applyBundleLanguage(to: defaults)
    XCTAssertEqual(defaults.stringArray(forKey: "AppleLanguages"), ["en"])

    AppLanguagePreference.system.applyBundleLanguage(to: defaults)
    XCTAssertEqual(defaults.stringArray(forKey: "AppleLanguages"), ["fr"])
  }

  func testSystemPreferenceDoesNotClearUnmanagedPerAppLanguage() throws {
    let suiteName = "AppLanguagePreferenceTests-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set(["en"], forKey: "AppleLanguages")

    AppLanguagePreference.system.applyBundleLanguage(to: defaults)

    XCTAssertEqual(defaults.stringArray(forKey: "AppleLanguages"), ["en"])
  }
}
