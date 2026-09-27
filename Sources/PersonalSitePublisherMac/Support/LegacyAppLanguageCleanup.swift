import Foundation

/// Retires the language override written by older versions of the app.
enum LegacyAppLanguageCleanup {
  private static let preferenceKey = "appLanguagePreferenceV1"
  private static let managedKey = "appLanguageManagesAppleLanguagesV1"
  private static let previousKey = "appLanguagePreviousAppleLanguagesV1"
  private static let hadPreviousKey = "appLanguageHadPreviousAppleLanguagesV1"
  private static let appleLanguagesKey = "AppleLanguages"

  static func prepareForLaunch(
    defaults: UserDefaults = .standard,
    processArguments: [String] = ProcessInfo.processInfo.arguments
  ) {
    // Command-line language overrides are temporary and must remain in force
    // for this launch. Retry the migration on the next ordinary launch.
    guard !processArguments.contains("-AppleLanguages") else { return }

    if defaults.bool(forKey: managedKey),
      let currentLanguages = defaults.stringArray(forKey: appleLanguagesKey),
      isStillManagedOverride(
        currentLanguages,
        storedPreference: defaults.string(forKey: preferenceKey)
      )
    {
      if defaults.bool(forKey: hadPreviousKey),
        let previousLanguages = defaults.stringArray(forKey: previousKey)
      {
        defaults.set(previousLanguages, forKey: appleLanguagesKey)
      } else if !defaults.bool(forKey: hadPreviousKey) {
        defaults.removeObject(forKey: appleLanguagesKey)
      }
    }

    for key in [preferenceKey, managedKey, previousKey, hadPreviousKey] {
      defaults.removeObject(forKey: key)
    }
  }

  private static func isStillManagedOverride(
    _ languages: [String],
    storedPreference: String?
  ) -> Bool {
    switch storedPreference {
    case "english": return languages == ["en"]
    case "simplifiedChinese": return languages == ["zh-Hans"]
    default: return languages == ["en"] || languages == ["zh-Hans"]
    }
  }
}
