import Foundation

/// UserDefaults keys shared by the RSS settings page, reader workspace, and
/// launch coordinator. Article-level switches remain transient view state;
/// these values describe app-wide automation and reader defaults.
enum RSSReaderUserPreferences {
  static let backgroundRefreshEnabledKey = "rssReaderBackgroundRefreshEnabled"
  static let backgroundRefreshIntervalMinutesKey = "rssReaderBackgroundRefreshIntervalMinutes"
  static let automaticMarkReadAtEndEnabledKey = "rssReaderAutomaticMarkReadAtEndEnabled"
  static let automaticTranslationEnabledKey = "rssReaderAutomaticTranslationEnabled"
  static let remoteImagesEnabledKey = "rssReaderRemoteImagesEnabled"
  static let offlineCacheFullTextOnRefreshEnabledKey = "rssReaderOfflineCacheFullTextOnRefreshEnabled"
  static let automaticFullTextExtractionEnabledKey = "rssReaderAutomaticFullTextExtractionEnabled"

  static let defaultBackgroundRefreshEnabled = true
  static let defaultBackgroundRefreshIntervalMinutes = 30
  static let defaultAutomaticMarkReadAtEndEnabled = true
  static let defaultAutomaticTranslationEnabled = false
  static let defaultRemoteImagesEnabled = false
  static let defaultOfflineCacheFullTextOnRefreshEnabled = false
  static let defaultAutomaticFullTextExtractionEnabled = false

  /// The menu intentionally exposes a small set of predictable values. Keep
  /// this list in one place so persisted values, settings UI, and launch
  /// configuration cannot drift apart.
  static let backgroundRefreshIntervalOptions = [15, 30, 60, 120]

  static func normalizedBackgroundRefreshIntervalMinutes(_ value: Int) -> Int {
    guard !backgroundRefreshIntervalOptions.isEmpty else {
      return defaultBackgroundRefreshIntervalMinutes
    }
    return backgroundRefreshIntervalOptions.min { lhs, rhs in
      let leftDistance = abs(lhs - value)
      let rightDistance = abs(rhs - value)
      if leftDistance != rightDistance { return leftDistance < rightDistance }
      return lhs < rhs
    } ?? defaultBackgroundRefreshIntervalMinutes
  }

  static func backgroundRefreshIntervalSeconds(_ minutes: Int) -> TimeInterval {
    TimeInterval(normalizedBackgroundRefreshIntervalMinutes(minutes) * 60)
  }

  static func backgroundRefreshEnabled(defaults: UserDefaults = .standard) -> Bool {
    defaults.object(forKey: backgroundRefreshEnabledKey) as? Bool
      ?? defaultBackgroundRefreshEnabled
  }

  static func backgroundRefreshIntervalMinutes(defaults: UserDefaults = .standard) -> Int {
    let storedValue = defaults.object(forKey: backgroundRefreshIntervalMinutesKey) as? Int
      ?? defaultBackgroundRefreshIntervalMinutes
    return normalizedBackgroundRefreshIntervalMinutes(storedValue)
  }

  static func automaticMarkReadAtEndEnabled(defaults: UserDefaults = .standard) -> Bool {
    defaults.object(forKey: automaticMarkReadAtEndEnabledKey) as? Bool
      ?? defaultAutomaticMarkReadAtEndEnabled
  }

  static func offlineCacheFullTextOnRefreshEnabled(defaults: UserDefaults = .standard) -> Bool {
    defaults.object(forKey: offlineCacheFullTextOnRefreshEnabledKey) as? Bool
      ?? defaultOfflineCacheFullTextOnRefreshEnabled
  }

  static func automaticFullTextExtractionEnabled(defaults: UserDefaults = .standard) -> Bool {
    defaults.object(forKey: automaticFullTextExtractionEnabledKey) as? Bool
      ?? defaultAutomaticFullTextExtractionEnabled
  }

  static func shouldAutomaticallyMarkReadAtEnd(
    enabled: Bool,
    previousProgress: Double?,
    progress: Double
  ) -> Bool {
    enabled && RSSReadingCompletionPolicy.didCrossCompletionThreshold(
      previousProgress: previousProgress,
      progress: progress
    )
  }
}

enum RSSReaderBackgroundRefreshPolicy {
  static func shouldRefreshStaleFeedsOnEntry(
    isSceneActive: Bool,
    isSafeMode: Bool,
    isEnabled: Bool,
    isRSSSectionSelected: Bool
  ) -> Bool {
    isSceneActive && !isSafeMode && isEnabled && isRSSSectionSelected
  }
}
