import Foundation

enum AppLanguagePreference: String, CaseIterable, Identifiable {
  case system
  case simplifiedChinese
  case english

  static let storageKey = "appLanguagePreferenceV1"

  private static let appleLanguagesKey = "AppleLanguages"
  private static let managesAppleLanguagesKey = "appLanguageManagesAppleLanguagesV1"
  private static let previousAppleLanguagesKey = "appLanguagePreviousAppleLanguagesV1"
  private static let hadPreviousAppleLanguagesKey = "appLanguageHadPreviousAppleLanguagesV1"

  var id: String { rawValue }

  var languageIdentifier: String? {
    switch self {
    case .system:
      return nil
    case .simplifiedChinese:
      return "zh-Hans"
    case .english:
      return "en"
    }
  }

  static func prepareForLaunch(
    defaults: UserDefaults = .standard,
    processArguments: [String] = ProcessInfo.processInfo.arguments
  ) {
    // Explicit launch arguments are used by UI automation and by macOS tooling
    // to request a one-off language. Respect that higher-priority override
    // instead of replacing it with the app's persisted preference.
    guard !processArguments.contains("-AppleLanguages") else { return }

    let preference =
      defaults.string(forKey: storageKey)
      .flatMap(AppLanguagePreference.init(rawValue:)) ?? .system
    preference.applyBundleLanguage(to: defaults)
  }

  func applyBundleLanguage(to defaults: UserDefaults = .standard) {
    switch self {
    case .system:
      Self.restorePreviousAppleLanguages(in: defaults)
    case .simplifiedChinese, .english:
      Self.capturePreviousAppleLanguagesIfNeeded(in: defaults)
      defaults.set([languageIdentifier].compactMap { $0 }, forKey: Self.appleLanguagesKey)
    }
  }

  private static func capturePreviousAppleLanguagesIfNeeded(in defaults: UserDefaults) {
    guard !defaults.bool(forKey: managesAppleLanguagesKey) else { return }

    if let previousLanguages = defaults.stringArray(forKey: appleLanguagesKey) {
      defaults.set(previousLanguages, forKey: previousAppleLanguagesKey)
      defaults.set(true, forKey: hadPreviousAppleLanguagesKey)
    } else {
      defaults.removeObject(forKey: previousAppleLanguagesKey)
      defaults.set(false, forKey: hadPreviousAppleLanguagesKey)
    }
    defaults.set(true, forKey: managesAppleLanguagesKey)
  }

  private static func restorePreviousAppleLanguages(in defaults: UserDefaults) {
    guard defaults.bool(forKey: managesAppleLanguagesKey) else { return }

    if defaults.bool(forKey: hadPreviousAppleLanguagesKey),
      let previousLanguages = defaults.stringArray(forKey: previousAppleLanguagesKey)
    {
      defaults.set(previousLanguages, forKey: appleLanguagesKey)
    } else {
      defaults.removeObject(forKey: appleLanguagesKey)
    }
    defaults.removeObject(forKey: managesAppleLanguagesKey)
    defaults.removeObject(forKey: previousAppleLanguagesKey)
    defaults.removeObject(forKey: hadPreviousAppleLanguagesKey)
  }
}
