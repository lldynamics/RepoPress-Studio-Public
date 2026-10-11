import SwiftUI

enum PublishingStatusArea {
  case repository
  case draft
  case deployment

  var title: String {
    switch self {
    case .repository:
      return String(localized: "仓库")
    case .draft:
      return String(localized: "当前文章")
    case .deployment:
      return String(localized: "发布历史")
    }
  }

  var systemImage: String {
    switch self {
    case .repository:
      return "externaldrive"
    case .draft:
      return "doc.text"
    case .deployment:
      return "clock.arrow.circlepath"
    }
  }

}

struct PublishingStatusPopoverItem: Identifiable {
  let area: PublishingStatusArea
  let value: String
  let detail: String
  let statusImage: String
  let color: Color
  let severity: PublishingStatusSeverity
  var count: Int? = nil

  var id: String { area.title }
}

enum PublishingStatusSeverity: Int {
  case ready
  case pending
  case information
  case active
  case warning
  case error

  var symbol: String {
    switch self {
    case .ready:
      return "checkmark.circle.fill"
    case .pending:
      return "clock.fill"
    case .information:
      return "info.circle.fill"
    case .active:
      return "arrow.triangle.2.circlepath.circle.fill"
    case .warning:
      return "exclamationmark.triangle.fill"
    case .error:
      return "xmark.circle.fill"
    }
  }
}
