import Foundation
import PublishingWorkbenchCore

/// A display-only classification; Git payloads and publish plans stay unchanged.
enum RepositoryDisplayChangeRole: CaseIterable, Hashable {
  case structure, article, image, configuration, other

  var localizedTitle: String {
    switch self {
    case .article: String(localized: "文章变更")
    case .structure: String(localized: "栏目结构页")
    case .image: String(localized: "图片变更")
    case .configuration: String(localized: "配置变更")
    case .other: String(localized: "其他变更")
    }
  }
}

struct RepositoryStructuralChangePresentation {
  private let groupedFiles: [RepositoryDisplayChangeRole: [RepositoryChangedFile]]

  init(report: RepositoryScanReport, profile: SiteProfile, isRemote: Bool = false) {
    var groups: [RepositoryDisplayChangeRole: [RepositoryChangedFile]] = [:]
    for file in isRemote ? report.remoteChangedFiles : report.changedFiles {
      let role: RepositoryDisplayChangeRole
      if Self.isStructural(file, profile: profile) {
        role = .structure
      } else {
        switch report.role(
          for: file, contentRoot: profile.contentRoot, assetRoot: profile.assetRoot)
        {
        case .article: role = .article
        case .image: role = .image
        case .configuration: role = .configuration
        case .other: role = .other
        }
      }
      groups[role, default: []].append(file)
    }
    groupedFiles = groups
  }

  static func isStructural(_ file: RepositoryChangedFile, profile: SiteProfile) -> Bool {
    // Renaming a section away from its protected name still changes site structure.
    ([file.destinationPath] + [file.sourcePath].compactMap { $0 }).contains {
      StructuralArticlePathPolicy.isProtected($0, profile: profile)
    }
  }

  func files(for role: RepositoryDisplayChangeRole) -> [RepositoryChangedFile] {
    groupedFiles[role] ?? []
  }

  var articleCount: Int { files(for: .article).count }
  var structuralCount: Int { files(for: .structure).count }
  var imageCount: Int { files(for: .image).count }
  var configurationCount: Int { files(for: .configuration).count }
  var otherCount: Int { files(for: .other).count }
  var totalCount: Int { groupedFiles.values.reduce(0) { $0 + $1.count } }
  var publishRelevantCount: Int { totalCount - otherCount }
  var importableArticles: [RepositoryChangedFile] {
    files(for: .article).filter { $0.kind != .deleted }
  }
}
