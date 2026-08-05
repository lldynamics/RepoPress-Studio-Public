import Foundation

enum RSSReadingTheme: String, CaseIterable, Identifiable {
  case system
  case warmPaper
  case white
  case dark

  var id: String { rawValue }

  var title: String {
    switch self {
    case .system: String(localized: "跟随系统")
    case .warmPaper: String(localized: "暖纸")
    case .white: String(localized: "纯白")
    case .dark: String(localized: "暗色")
    }
  }

  var systemImage: String {
    switch self {
    case .system: "circle.lefthalf.filled"
    case .warmPaper: "sun.max"
    case .white: "doc.plaintext"
    case .dark: "moon"
    }
  }

  var cssColorScheme: String {
    switch self {
    case .system: "light dark"
    case .warmPaper, .white: "light"
    case .dark: "dark"
    }
  }

  var cssBackground: String {
    switch self {
    case .system: "transparent"
    case .warmPaper: "#f7f0df"
    case .white: "#ffffff"
    case .dark: "#1c1c1e"
    }
  }

  var cssForeground: String {
    switch self {
    case .system: "-apple-system-label"
    case .warmPaper: "#302b23"
    case .white: "#1d1d1f"
    case .dark: "#f5f5f7"
    }
  }

  var cssSecondaryForeground: String {
    switch self {
    case .system: "-apple-system-secondary-label"
    case .warmPaper: "#6f6658"
    case .white: "#6e6e73"
    case .dark: "#b5b5bd"
    }
  }

  var cssLink: String {
    switch self {
    case .system: "-apple-system-link"
    case .warmPaper: "#8a4b20"
    case .white: "#0066cc"
    case .dark: "#64b5ff"
    }
  }
}

enum RSSReadingComfortConfiguration {
  static let fontSizeRange = 13.0 ... 24.0
  static let lineSpacingRange = 1.35 ... 2.10
  static let defaultFontSize = 17.0
  static let defaultLineSpacing = 1.65
}

enum RSSReadingProgressStore {
  private static let key = "rssReadingProgressByArticle"
  private static let orderKey = "rssReadingProgressArticleOrder"
  static let maximumEntryCount = 512

  static func load(defaults: UserDefaults = .standard) -> [String: Double] {
    guard let data = defaults.data(forKey: key),
          let values = try? JSONDecoder().decode([String: Double].self, from: data)
    else {
      return [:]
    }
    return normalized(values, preferredOrder: loadOrder(defaults: defaults))
  }

  static func loadOrder(defaults: UserDefaults = .standard) -> [String] {
    guard let data = defaults.data(forKey: orderKey),
          let values = try? JSONDecoder().decode([String].self, from: data)
    else {
      return []
    }
    return uniqueIDs(values)
  }

  static func save(
    _ values: [String: Double],
    defaults: UserDefaults = .standard
  ) {
    save(
      values,
      orderedArticleIDs: loadOrder(defaults: defaults),
      defaults: defaults
    )
  }

  static func save(
    _ values: [String: Double],
    orderedArticleIDs: [String],
    defaults: UserDefaults = .standard
  ) {
    let values = normalized(values, preferredOrder: orderedArticleIDs)
    let order = Self.orderedArticleIDs(for: values, preferredOrder: orderedArticleIDs)
    guard let data = try? JSONEncoder().encode(values),
          let orderData = try? JSONEncoder().encode(order)
    else { return }
    defaults.set(data, forKey: key)
    defaults.set(orderData, forKey: orderKey)
  }

  private static func normalized(
    _ values: [String: Double],
    preferredOrder: [String]
  ) -> [String: Double] {
    let sanitized = values.reduce(into: [String: Double]()) { result, entry in
      guard entry.value.isFinite else { return }
      result[entry.key] = min(max(entry.value, 0), 1)
    }

    let ids = orderedArticleIDs(for: sanitized, preferredOrder: preferredOrder)
    return ids.reduce(into: [String: Double]()) { result, id in
      if let value = sanitized[id] {
        result[id] = value
      }
    }
  }

  private static func orderedArticleIDs(
    for values: [String: Double],
    preferredOrder: [String]
  ) -> [String] {
    var result: [String] = []
    var seen = Set<String>()
    for id in uniqueIDs(preferredOrder) where values[id] != nil {
      result.append(id)
      seen.insert(id)
    }
    for id in values.keys.sorted() where seen.insert(id).inserted {
      result.append(id)
    }
    return Array(result.prefix(maximumEntryCount))
  }

  private static func uniqueIDs(_ values: [String]) -> [String] {
    var result: [String] = []
    var seen = Set<String>()
    for value in values where !value.isEmpty && seen.insert(value).inserted {
      result.append(value)
    }
    return result
  }
}

actor RSSReadingProgressPersistence {
  static let shared = RSSReadingProgressPersistence()

  private let defaults: UserDefaults
  private var latestSavedRevision: UInt64?

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  func save(
    _ values: [String: Double],
    orderedArticleIDs: [String],
    revision: UInt64
  ) {
    if let latestSavedRevision, revision <= latestSavedRevision {
      return
    }
    latestSavedRevision = revision
    RSSReadingProgressStore.save(
      values,
      orderedArticleIDs: orderedArticleIDs,
      defaults: defaults
    )
  }
}

@MainActor
enum RSSReadingProgressPersistenceRevision {
  private static var current: UInt64 = 0

  static func next() -> UInt64 {
    current &+= 1
    return current
  }
}

enum RSSReadingCompletionPolicy {
  static let completionThreshold = 0.995

  static func shouldAutomaticallyMarkRead(progress: Double) -> Bool {
    progress.isFinite && progress >= completionThreshold
  }
}
