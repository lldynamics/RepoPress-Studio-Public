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

  private static var localizedBundle: Bundle {
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
  }

  private static func bundle(for locale: Locale) -> Bundle {
    let language = locale.identifier.lowercased().hasPrefix("zh") ? "zh-Hans" : "en"
    let rootBundle = localizedBundle
    let bundleURL = rootBundle.bundleURL
      .appendingPathComponent("\(language).lproj", isDirectory: true)
    guard let bundle = Bundle(url: bundleURL) else {
      return rootBundle
    }
    return bundle
  }
}
