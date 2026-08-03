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

  static func load() -> [String: Double] {
    guard let data = UserDefaults.standard.data(forKey: key),
          let values = try? JSONDecoder().decode([String: Double].self, from: data)
    else {
      return [:]
    }
    return values.reduce(into: [:]) { result, entry in
      guard entry.value.isFinite else { return }
      result[entry.key] = min(max(entry.value, 0), 1)
    }
  }

  static func save(_ values: [String: Double]) {
    guard let data = try? JSONEncoder().encode(values) else { return }
    UserDefaults.standard.set(data, forKey: key)
  }
}
