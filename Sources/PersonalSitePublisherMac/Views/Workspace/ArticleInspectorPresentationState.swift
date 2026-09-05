import Combine
import Foundation
import PublishingWorkbenchCore
import SwiftUI

/// Keeps article Inspector choices local to one native Inspector column.
///
/// `MetadataColumn` owns this object, so its selections survive an AI surface
/// swap but are released with the window's Inspector. The section belongs in
/// the key because the same article has separate useful defaults in Writing,
/// Images, and Content Health.
@MainActor
final class ArticleInspectorPresentationState: ObservableObject {
  private struct SelectionKey: Hashable {
    let draftID: UUID
    let section: WorkspaceSection
  }

  @Published private var selectedTabs: [SelectionKey: ArticleInspectorTab] = [:]

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
}
