import Foundation

/// Localizes user-facing presentation copy produced inside the Core target.
///
/// Core owns a separate resource bundle from the app target, so dynamic status,
/// validation, and error strings must be resolved here instead of relying on a
/// SwiftUI `Text` call to localize them later.
enum CoreL10n {
  static func text(_ key: String) -> String {
    localizedBundle.localizedString(forKey: key, value: key, table: nil)
  }

  static func format(_ key: String, _ arguments: CVarArg...) -> String {
    String(
      format: text(key),
      locale: .autoupdatingCurrent,
      arguments: arguments
    )
  }

  static func text(_ key: String, locale: Locale) -> String {
    bundle(for: locale).localizedString(forKey: key, value: key, table: nil)
  }

  static func format(_ key: String, locale: Locale, arguments: [CVarArg]) -> String {
    String(format: text(key, locale: locale), locale: locale, arguments: arguments)
  }

  private static var localizedBundle: Bundle {
    Bundle.module
  }

  private static func bundle(for locale: Locale) -> Bundle {
    let language = locale.identifier.lowercased().hasPrefix("zh") ? "zh-Hans" : "en"
    guard let path = Bundle.module.path(forResource: language, ofType: "lproj"),
          let bundle = Bundle(path: path) else {
      return Bundle.module
    }
    return bundle
  }
}
