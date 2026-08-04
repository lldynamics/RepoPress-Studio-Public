import SwiftUI

enum KnowledgeSidebarDensity: String, CaseIterable, Identifiable {
  case comfortable
  case compact

  var id: String { rawValue }

  var localizedTitle: LocalizedStringKey {
    switch self {
    case .comfortable: "舒适"
    case .compact: "紧凑"
    }
  }

  var listRowInsets: EdgeInsets {
    switch self {
    case .comfortable:
      EdgeInsets(top: 5, leading: 8, bottom: 5, trailing: 8)
    case .compact:
      EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8)
    }
  }

  var rowTextSpacing: CGFloat {
    self == .comfortable ? 3 : 1
  }

  var collectionRowVerticalPadding: CGFloat {
    self == .comfortable ? 5 : 3
  }

  var collectionRowMinimumHeight: CGFloat {
    self == .comfortable ? 30 : 24
  }
}
