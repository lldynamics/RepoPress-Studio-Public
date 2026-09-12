import Combine
import Foundation

/// Persisted presentation choices for one workspace window's writing list.
///
/// This contains only list controls and opaque folder identifiers.  Article
/// contents remain in the publishing store and are never copied into scene
/// restoration storage.
@MainActor
final class WritingListWindowPresentationState: ObservableObject {
  struct StorageValues: Equatable {
    let searchText: String
    let filterRawValue: String
    let displayModeRawValue: String
    let sortOrderRawValue: String
    let expandedFolderIDsData: String
  }

  @Published var searchText = ""
  @Published var filter: DraftListFilter = .all
  @Published var displayMode: WritingDraftListDisplayMode = .flat
  @Published var sortOrder: WritingDraftSortOrder = .updatedNewest
  @Published private(set) var userExpandedFolderIDs: Set<String> = []
  @Published private(set) var restorationRevision = 0
  private(set) var hasPersistedFolderExpansion = false

  private var didRestoreStorage = false

  var storageValues: StorageValues {
    StorageValues(
      searchText: searchText,
      filterRawValue: filter.rawValue,
      displayModeRawValue: displayMode.rawValue,
      sortOrderRawValue: sortOrder.rawValue,
      expandedFolderIDsData: Self.encodeFolderIDs(userExpandedFolderIDs)
    )
  }

  @discardableResult
  func restoreStorageIfNeeded(
    searchText: String,
    filterRawValue: String,
    displayModeRawValue: String,
    sortOrderRawValue: String,
    expandedFolderIDsData: String
  ) -> StorageValues {
    guard !didRestoreStorage else { return storageValues }
    didRestoreStorage = true

    self.searchText = searchText
    filter = DraftListFilter(rawValue: filterRawValue) ?? .all
    displayMode = WritingDraftListDisplayMode(rawValue: displayModeRawValue) ?? .flat
    sortOrder = WritingDraftSortOrder(rawValue: sortOrderRawValue) ?? .updatedNewest
    if let restoredFolderIDs = Self.decodeFolderIDs(expandedFolderIDsData) {
      userExpandedFolderIDs = restoredFolderIDs
      hasPersistedFolderExpansion = true
    } else {
      userExpandedFolderIDs = []
    }
    restorationRevision &+= 1
    return storageValues
  }

  func setUserExpandedFolderIDs(_ folderIDs: Set<String>) {
    guard userExpandedFolderIDs != folderIDs else { return }
    userExpandedFolderIDs = folderIDs
  }

  func makeFolderExpansionState() -> WritingDraftFolderExpansionState {
    WritingDraftFolderExpansionState(initiallyExpandedFolderIDs: userExpandedFolderIDs)
  }

  private static func encodeFolderIDs(_ folderIDs: Set<String>) -> String {
    guard let data = try? JSONEncoder().encode(folderIDs.sorted()),
          let encoded = String(data: data, encoding: .utf8)
    else {
      return ""
    }
    return encoded
  }

  private static func decodeFolderIDs(_ encoded: String) -> Set<String>? {
    guard let data = encoded.data(using: .utf8),
          let values = try? JSONDecoder().decode([String].self, from: data)
    else {
      return nil
    }
    return Set(values)
  }
}
