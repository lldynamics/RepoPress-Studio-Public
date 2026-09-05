import Foundation

enum PublishScope: String, CaseIterable, Identifiable {
  case repository
  case managedArticles
  case currentArticle

  var id: String { rawValue }
  var title: String {
    switch self {
    case .repository: String(localized: "整个仓库")
    case .managedArticles: String(localized: "应用文章")
    case .currentArticle: String(localized: "当前文章")
    }
  }
}
