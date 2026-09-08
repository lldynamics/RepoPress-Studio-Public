import Foundation

/// Pointer selection changes the activation target without requesting a scroll.
/// Only keyboard navigation and result replacement can move the viewport.
struct WorkspaceCommandPaletteSelection {
  private(set) var selectedID: String?
  private(set) var scrollRevision = 0

  mutating func select(_ id: String) {
    selectedID = id
  }

  mutating func synchronize(with resultIDs: [String]) {
    guard selectedID.map(resultIDs.contains) != true else { return }
    selectedID = resultIDs.first
    scrollRevision &+= 1
  }

  mutating func move(by offset: Int, among resultIDs: [String]) {
    guard !resultIDs.isEmpty else {
      selectedID = nil
      return
    }
    if let selectedID, let index = resultIDs.firstIndex(of: selectedID) {
      let count = resultIDs.count
      let nextIndex = ((index + offset % count) % count + count) % count
      self.selectedID = resultIDs[nextIndex]
    } else {
      selectedID = resultIDs.first
    }
    scrollRevision &+= 1
  }
}
