import Combine
import Foundation
import PublishingWorkbenchCore
import SwiftUI

/// Keeps article Inspector choices and information-group expansion local to one window.
///
/// `ContentView` owns this object, so its selections survive Inspector mounting,
/// width changes, and an AI surface swap, and remain local to the window. The section belongs in
/// the key because the same article has separate useful defaults in Writing,
/// Images, and Content Health.
@MainActor
final class ArticleInspectorPresentationState: ObservableObject {
  private struct SelectionKey: Hashable {
    let draftID: UUID
    let section: WorkspaceSection
  }

  @Published private var selectedTabs: [SelectionKey: ArticleInspectorTab] = [:]
  @Published private var expandedGroups: [SelectionKey: Set<ArticleInspectorTab>] = [:]
  @Published private var expandedAdvancedMetadata: Set<SelectionKey> = []

  func advancedMetadataBinding(for draftID: UUID, section: WorkspaceSection) -> Binding<Bool> {
    let key = SelectionKey(draftID: draftID, section: section)
    return Binding(
      get: { [weak self] in self?.expandedAdvancedMetadata.contains(key) ?? false },
      set: { [weak self] expanded in
        if expanded {
          self?.expandedAdvancedMetadata.insert(key)
        } else {
          self?.expandedAdvancedMetadata.remove(key)
        }
      }
    )
  }

  /// A publishing repair must expose its field before the caller scrolls to it.
  func revealMetadataField(_ field: String, for draftID: UUID, section: WorkspaceSection) {
    setExpanded(true, group: .metadata, for: draftID, section: section)
    if field == "slug" {
      expandedAdvancedMetadata.insert(SelectionKey(draftID: draftID, section: section))
    }
  }

  /// Screenshot navigation needs the visible group as well as the selected tab.
  @discardableResult
  func revealSEOSocialPreview(for draftID: UUID, section: WorkspaceSection) -> Bool {
    guard section == .writing else { return false }
    setExpanded(false, group: .metadata, for: draftID, section: section)
    select(.seo, for: draftID, section: section)
    return true
  }

  func selectedTab(
    for draftID: UUID,
    section: WorkspaceSection,
    defaultTab: ArticleInspectorTab
  ) -> ArticleInspectorTab {
    selectedTabs[SelectionKey(draftID: draftID, section: section)] ?? defaultTab
  }

  func select(
    _ tab: ArticleInspectorTab,
    for draftID: UUID,
    section: WorkspaceSection
  ) {
    let key = SelectionKey(draftID: draftID, section: section)
    // Navigation must reopen a group even when it selects the same target again.
    if section == .writing, tab != .checks {
      setExpanded(true, group: tab, for: draftID, section: section)
    }
    guard selectedTabs[key] != tab else { return }
    selectedTabs[key] = tab
  }

  func binding(
    for draftID: UUID,
    section: WorkspaceSection,
    defaultTab: ArticleInspectorTab
  ) -> Binding<ArticleInspectorTab> {
    Binding(
      get: { [weak self] in
        guard let self else { return defaultTab }
        return self.selectedTab(
          for: draftID,
          section: section,
          defaultTab: defaultTab
        )
      },
      set: { [weak self] tab in
        self?.select(tab, for: draftID, section: section)
      }
    )
  }

  func isExpanded(
    _ group: ArticleInspectorTab,
    for draftID: UUID,
    section: WorkspaceSection
  ) -> Bool {
    let key = SelectionKey(draftID: draftID, section: section)
    return (expandedGroups[key] ?? [.metadata]).contains(group)
  }

  func setExpanded(
    _ isExpanded: Bool,
    group: ArticleInspectorTab,
    for draftID: UUID,
    section: WorkspaceSection
  ) {
    let key = SelectionKey(draftID: draftID, section: section)
    var groups = expandedGroups[key] ?? [.metadata]
    if isExpanded { groups.insert(group) } else { groups.remove(group) }
    guard expandedGroups[key] != groups else { return }
    expandedGroups[key] = groups
  }

  func expansionBinding(
    for group: ArticleInspectorTab,
    draftID: UUID,
    section: WorkspaceSection
  ) -> Binding<Bool> {
    Binding(
      get: { [weak self] in
        self?.isExpanded(group, for: draftID, section: section) ?? (group == .metadata)
      },
      set: { [weak self] in
        self?.setExpanded($0, group: group, for: draftID, section: section)
      }
    )
  }
}

enum ArticleInspectorTab: String, CaseIterable, Identifiable {
  case knowledge
  case metadata
  case seo
  case images
  case checks

  var id: String { rawValue }

  var informationAnchor: String { "article-inspector-group-" + rawValue }

  var informationTitle: String {
    switch self {
    case .metadata: String(localized: "元数据")
    case .seo: String(localized: "SEO 与分享")
    case .images: String(localized: "封面与图片")
    case .knowledge: String(localized: "相关资料")
    case .checks: title
    }
  }

  var title: String {
    switch self {
    case .knowledge:
      return String(localized: "上下文知识建议")
    case .metadata:
      return String(localized: "元数据")
    case .seo:
      return "SEO"
    case .images:
      return String(localized: "图片")
    case .checks:
      return String(localized: "检查")
    }
  }

  var systemImage: String {
    switch self {
    case .knowledge:
      return "books.vertical"
    case .metadata:
      return "slider.horizontal.3"
    case .seo:
      return "chart.bar.doc.horizontal"
    case .images:
      return "photo.on.rectangle"
    case .checks:
      return "checklist"
    }
  }

  var pickerTitle: String {
    switch self {
    case .knowledge:
      return String(localized: "知识建议")
    case .metadata, .seo, .images, .checks:
      return title
    }
  }

  static func defaultTab(for section: WorkspaceSection) -> ArticleInspectorTab {
    switch section {
    case .writing:
      return .metadata
    case .sync:
      return .metadata
    case .contentHealth:
      return .checks
    case .images:
      return .images
    case .library, .rss:
      return .metadata
    }
  }

  static func availableTabs(for section: WorkspaceSection) -> [ArticleInspectorTab] {
    switch section {
    case .writing:
      return [.metadata, .seo, .images, .knowledge]
    case .contentHealth:
      return [.checks]
    case .images:
      return [.images]
    case .sync, .library, .rss:
      return []
    }
  }
}
