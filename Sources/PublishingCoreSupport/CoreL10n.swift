import Foundation

/// Localizes user-facing presentation copy produced inside the Core target.
///
/// Core owns a separate resource bundle from the app target, so dynamic status,
/// validation, and error strings must be resolved here instead of relying on a
/// SwiftUI `Text` call to localize them later.
public enum CoreL10n {
  public static func text(_ key: String) -> String {
    localizedBundle.localizedString(forKey: key, value: key, table: nil)
  }

  public static func format(_ key: String, _ arguments: CVarArg...) -> String {
    String(
      format: text(key),
      locale: .autoupdatingCurrent,
      arguments: arguments
    )
  }

  public static func text(_ key: String, locale: Locale) -> String {
    bundle(for: locale).localizedString(forKey: key, value: key, table: nil)
  }

  public static func format(_ key: String, locale: Locale, arguments: [CVarArg]) -> String {
    String(format: text(key, locale: locale), locale: locale, arguments: arguments)
  }

  private static let localizedBundle: Bundle = {
    let bundleNames = [
      "PersonalSitePublisherMac_PublishingCoreSupport.bundle",
      "PersonalSitePublisherMac_PublishingWorkbenchCore.bundle",
    ]
    for bundleName in bundleNames {
      if let packagedBundleURL = Bundle.main.resourceURL?
        .appendingPathComponent(bundleName),
         let packagedBundle = Bundle(url: packagedBundleURL) {
        return packagedBundle
      }
    }
    return Bundle.module
  }()

  private static let chineseBundle = bundle(forLanguage: "zh-Hans")
  private static let englishBundle = bundle(forLanguage: "en")

  private static func bundle(for locale: Locale) -> Bundle {
    locale.identifier.lowercased().hasPrefix("zh") ? chineseBundle : englishBundle
  }

  /// SwiftPM's native driver emits a flat resource bundle, while Swift Build
  /// and packaged apps use a standard bundle with `Contents/Resources`, and
  /// folder names may be lowercased (`zh-hans.lproj`). Locating the folder
  /// under `resourceURL` keeps an explicit locale from silently falling back
  /// to the user's preferred language.
  private static func bundle(forLanguage language: String) -> Bundle {
    localization(language, in: localizedBundle) ?? localizedBundle
  }

  static func localization(_ language: String, in bundle: Bundle) -> Bundle? {
    let resourceRoot = bundle.resourceURL ?? bundle.bundleURL
    let entries =
      (try? FileManager.default.contentsOfDirectory(
        at: resourceRoot, includingPropertiesForKeys: nil)) ?? []
    return entries.first(where: {
      $0.pathExtension == "lproj"
        && $0.deletingPathExtension().lastPathComponent
          .caseInsensitiveCompare(language) == .orderedSame
    }).flatMap(Bundle.init(url:))
  }
}
