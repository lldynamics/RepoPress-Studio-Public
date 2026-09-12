import SwiftUI

/// Scene restoration is kept beside the scene instead of in shared defaults.
/// Observing list choices here also keeps typing out of the root store.
struct WritingListWindowStorageModifier: ViewModifier {
  @ObservedObject var state: WritingListWindowPresentationState
  @SceneStorage("workspace.writingList.searchText") private var searchText = ""
  @SceneStorage("workspace.writingList.filter") private var filter = "all"
  @SceneStorage("workspace.writingList.displayMode") private var displayMode = "flat"
  @SceneStorage("workspace.writingList.sortOrder") private var sortOrder = "updatedNewest"
  @SceneStorage("workspace.writingList.expandedFolderIDs") private var expandedFolderIDs = ""

  func body(content: Content) -> some View {
    content
      .onAppear {
        persist(
          state.restoreStorageIfNeeded(
            searchText: searchText,
            filterRawValue: filter, displayModeRawValue: displayMode,
            sortOrderRawValue: sortOrder, expandedFolderIDsData: expandedFolderIDs))
      }
      .onChange(of: state.storageValues) { _, values in persist(values) }
  }

  private func persist(_ values: WritingListWindowPresentationState.StorageValues) {
    searchText = values.searchText
    filter = values.filterRawValue
    displayMode = values.displayModeRawValue
    sortOrder = values.sortOrderRawValue
    expandedFolderIDs = values.expandedFolderIDsData
  }
}
