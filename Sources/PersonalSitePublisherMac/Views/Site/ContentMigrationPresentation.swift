import SwiftUI

enum ContentMigrationNotice {
  case analyzing
  case ready
  case completed(inserted: Int, updated: Int)
  case unsupportedSource
  case unreadableSource(String)
  case invalidExport(String)
  case profileChanged
  case fileTooLarge
  case tooManyMarkdownFiles
  case copiedRedirectCSV
  case exportedRedirectCSV(String)
  case copyFailed
  case exportFailed(String)
  case failure(String)

  var isError: Bool {
    switch self {
    case .unsupportedSource, .unreadableSource, .invalidExport, .profileChanged,
      .fileTooLarge, .tooManyMarkdownFiles, .copyFailed, .exportFailed, .failure:
      true
    default:
      false
    }
  }
}

enum ContentMigrationLayout {
  static let metricMinimumWidth: CGFloat = 132
  static let emptyStateMinimumHeight: CGFloat = 220
}
