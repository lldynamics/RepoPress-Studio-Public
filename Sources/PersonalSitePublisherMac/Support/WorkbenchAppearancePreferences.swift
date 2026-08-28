import SwiftUI

enum WorkbenchAppearanceMode: String, CaseIterable, Identifiable {
  static let storageKey = "workbenchAppearanceModeV1"

  case system
  case light
  case dark

  var id: String { rawValue }

  var title: String {
    switch self {
    case .system:
      return String(localized: "跟随系统")
    case .light:
      return String(localized: "浅色")
    case .dark:
      return String(localized: "深色")
    }
  }

  var colorScheme: ColorScheme? {
    switch self {
    case .system:
      return nil
    case .light:
      return .light
    case .dark:
      return .dark
    }
  }

  static func resolved(rawValue: String?) -> WorkbenchAppearanceMode {
    rawValue.flatMap(Self.init(rawValue:)) ?? .system
  }
}

enum WorkbenchInterfaceDensity: String, CaseIterable, Identifiable {
  static let storageKey = "workbenchInterfaceDensityV1"

  case comfortable
  case compact

  var id: String { rawValue }

  var title: String {
    switch self {
    case .comfortable:
      return String(localized: "舒适")
    case .compact:
      return String(localized: "紧凑")
    }
  }

  var controlSize: ControlSize {
    switch self {
    case .comfortable:
      return .regular
    case .compact:
      return .small
    }
  }

  static func resolved(rawValue: String?) -> WorkbenchInterfaceDensity {
    rawValue.flatMap(Self.init(rawValue:)) ?? .comfortable
  }
}
