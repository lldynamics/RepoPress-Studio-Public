import Foundation
import PublishingWorkbenchCore
import SwiftUI

enum WorkspaceQuickSearchScope: Equatable {
  case recent
  case imageResources
  case aiFixes
}

/// The command palette is the one search entry point. These scopes select
/// local search corpora. Article results include live Markdown bodies;
/// no scope sends a query to an AI/provider.
enum WorkspaceUnifiedSearchScope: String, CaseIterable, Identifiable, Sendable {
  case all
  case articles
  case resources
  case rss
  case settings
  case commands

  var id: String { rawValue }

  var title: String {
    switch self {
    case .all: String(localized: "全部")
    case .articles: String(localized: "文章")
    case .resources: String(localized: "资料")
    case .rss: "RSS"
    case .settings: String(localized: "设置")
    case .commands: String(localized: "命令")
    }
  }

  var includesCommands: Bool { self == .all || self == .commands }
  var includesArticles: Bool { self == .all || self == .articles }
  var includesResources: Bool { self == .all || self == .resources }
  var includesRSS: Bool { self == .all || self == .rss }
  var includesSettings: Bool { self == .all || self == .settings }

  static func availableScopes(for moduleVisibility: WorkspaceModuleVisibility) -> [Self] {
    var scopes: [Self] = [.all, .articles]
    if moduleVisibility.libraryEnabled || moduleVisibility.imagesEnabled {
      scopes.append(.resources)
    }
    if moduleVisibility.rssEnabled {
      scopes.append(.rss)
    }
    scopes.append(contentsOf: [.settings, .commands])
    return scopes
  }

  func normalized(for moduleVisibility: WorkspaceModuleVisibility) -> Self {
    switch self {
    case .resources where !moduleVisibility.libraryEnabled && !moduleVisibility.imagesEnabled:
      return .all
    case .rss where !moduleVisibility.rssEnabled:
      return .all
    default:
      return self
    }
  }

}

enum WorkspaceUnifiedSearchPresentation {
  static let recentItemLimit = 6

  static func matchingSettings(
    query: String,
    recentItemIDs: [String] = [],
    moduleVisibility: WorkspaceModuleVisibility = .init()
  ) -> [SettingsSearchItem] {
    let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else {
      let byID = Dictionary(uniqueKeysWithValues: SettingsSearchIndex.allItems.map { ($0.id, $0) })
      let recent = recentItemIDs.compactMap { byID[$0] }
      let fallback = SettingsSearchIndex.allItems.filter { item in
        !recentItemIDs.contains(item.id)
      }
      return Array(
        (recent + fallback)
          .filter { item in moduleVisibility.rssEnabled || item.tab != .rss }
          .prefix(recentItemLimit)
      )
    }
    return SettingsSearchIndex.search(query: normalized).filter { item in
      moduleVisibility.rssEnabled || item.tab != .rss
    }
  }

  static func matchingSections(
    _ sections: [WorkspaceSection],
    query: String,
    scope: WorkspaceUnifiedSearchScope,
    moduleVisibility: WorkspaceModuleVisibility = .init()
  ) -> [WorkspaceSection] {
    let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedScope = scope.normalized(for: moduleVisibility)
    return sections.filter { section in
      guard moduleVisibility.allows(section) else { return false }
      let isInScope: Bool
      switch section {
      case .library, .images:
        isInScope = normalizedScope.includesResources
      case .rss:
        isInScope = normalizedScope.includesRSS
      case .writing, .sync, .contentHealth:
        isInScope = normalizedScope.includesCommands
      }
      guard isInScope else { return false }
      return normalized.isEmpty
        || workspaceNavigationLocalizedString(section.displayNameLocalizationKey)
          .localizedStandardContains(normalized)
        || section.rawValue.localizedStandardContains(normalized)
    }
  }
}

enum WorkspaceQuickSearchPresentation {
  static let recentResultLimit = 3
  static let searchResultLimit = 40

  static func resultSectionTitle(query: String, scope: WorkspaceQuickSearchScope) -> String {
    let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard normalizedQuery.isEmpty else { return "搜索结果" }
    switch scope {
    case .recent:
      return "最近变更"
    case .imageResources:
      return "图片资源"
    case .aiFixes:
      return String(localized: "AI 可修复")
    }
  }

  static func scopedDrafts(
    _ drafts: [ArticleDraft],
    includedDraftIDs: Set<UUID>?
  ) -> [ArticleDraft] {
    guard let includedDraftIDs else { return drafts }
    return drafts.filter { includedDraftIDs.contains($0.id) }
  }

  static func matchingDrafts(
    drafts: [ArticleDraft],
    query: String,
    preferredDraftIDs: [UUID]? = nil,
    matches: (ArticleDraft, String) -> Bool
  ) -> [ArticleDraft] {
    let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    let orderedDrafts: [ArticleDraft]
    if let preferredDraftIDs {
      var draftByID: [UUID: ArticleDraft] = [:]
      for draft in drafts where draftByID[draft.id] == nil {
        draftByID[draft.id] = draft
      }
      orderedDrafts = preferredDraftIDs.compactMap { draftByID[$0] }
    } else {
      orderedDrafts = drafts.sorted { lhs, rhs in
        if lhs.metadataUpdatedAt == rhs.metadataUpdatedAt {
          return lhs.id.uuidString < rhs.id.uuidString
        }
        return lhs.metadataUpdatedAt > rhs.metadataUpdatedAt
      }
    }
    guard !normalizedQuery.isEmpty else { return orderedDrafts }
    return orderedDrafts.filter { matches($0, normalizedQuery) }
  }

  static func visibleDrafts(from matches: [ArticleDraft], query: String) -> [ArticleDraft] {
    let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    let limit = normalizedQuery.isEmpty ? recentResultLimit : searchResultLimit
    return Array(matches.prefix(limit))
  }
}
