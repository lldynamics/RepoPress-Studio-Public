import SwiftUI

@MainActor
struct WorkspaceCommandSearchToolbarControl: View {
  @ObservedObject private var contextStore: WorkspaceToolbarEditorContextStore
  let selectedDraftID: UUID?
  let density: WorkspaceTopBarPresentation.Density
  let isEnabled: Bool
  let action: () -> Void

  init(
    contextStore: WorkspaceToolbarEditorContextStore,
    selectedDraftID: UUID?,
    density: WorkspaceTopBarPresentation.Density,
    isEnabled: Bool,
    action: @escaping () -> Void
  ) {
    _contextStore = ObservedObject(wrappedValue: contextStore)
    self.selectedDraftID = selectedDraftID
    self.density = density
    self.isEnabled = isEnabled
    self.action = action
  }

  var body: some View {
    WorkspaceCommandSearchNativeHost(
      density: density,
      statistics: statistics,
      isEnabled: isEnabled,
      action: action
    )
    .frame(width: WorkspaceTopBarPresentation.searchWidth(for: density), height: 28)
  }

  private var statistics: WorkspaceTopBarPresentation.ContextStatistics {
    guard let context = contextStore.context,
      context.draftID == selectedDraftID
    else {
      return .init()
    }
    return .init(
      wordCount: context.writingUnitCount,
      readingMinutes: context.readingMinutes
    )
  }
}
