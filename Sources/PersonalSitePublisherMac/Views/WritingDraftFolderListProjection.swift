import Foundation
import PublishingWorkbenchCore

/// A row-sized projection of the recursive core folder tree.
///
/// The writing sidebar still owns draft selection and pagination. This helper
/// only decides which folder headers and loaded draft rows are visible, keeping
/// the tree rendering independent from SwiftUI's `OutlineGroup` behavior.
struct WritingDraftFolderListEntry: Identifiable, Equatable, Hashable {
  enum Kind: Hashable {
    case folder
    case draft
  }

  let id: String
  let kind: Kind
  let depth: Int
  let folder: DraftFolderNode?
  let draftID: UUID?

  var isFolder: Bool { kind == .folder }

  var folderID: String? { folder?.id }

  static func folderEntry(_ folder: DraftFolderNode, depth: Int) -> Self {
    Self(
      id: "folder:\(folder.id)",
      kind: .folder,
      depth: depth,
      folder: folder,
      draftID: nil
    )
  }

  static func draftEntry(_ draftID: UUID, depth: Int) -> Self {
    Self(
      id: "draft:\(draftID.uuidString.lowercased())",
      kind: .draft,
      depth: depth,
      folder: nil,
      draftID: draftID
    )
  }
}

enum WritingDraftFolderListProjection {
  /// Flattens visible folders and loaded drafts in the core's deterministic
  /// order. Folder headers remain visible even when all of their drafts are
  /// beyond the current page, so a collapsed tree never becomes an empty
  /// state and each header can show its matching descendant count.
  static func flatten(
    root: DraftFolderNode,
    expandedFolderIDs: Set<String>,
    loadedDraftIDs: Set<UUID>
  ) -> [WritingDraftFolderListEntry] {
    var entries: [WritingDraftFolderListEntry] = []
    // Do not walk every descendant just to estimate capacity. Expansion is a
    // local operation: the real append pass below should be the only tree
    // traversal, and it stops at collapsed branches.
    entries.reserveCapacity(loadedDraftIDs.count + root.children.count)

    appendLoadedDrafts(
      root.draftIDs,
      depth: 0,
      loadedDraftIDs: loadedDraftIDs,
      into: &entries
    )
    for child in root.children {
      append(
        child,
        depth: 0,
        expandedFolderIDs: expandedFolderIDs,
        loadedDraftIDs: loadedDraftIDs,
        into: &entries
      )
    }
    return entries
  }

  private static func append(
    _ folder: DraftFolderNode,
    depth: Int,
    expandedFolderIDs: Set<String>,
    loadedDraftIDs: Set<UUID>,
    into entries: inout [WritingDraftFolderListEntry]
  ) {
    entries.append(.folderEntry(folder, depth: depth))
    guard expandedFolderIDs.contains(folder.id) else { return }

    appendLoadedDrafts(
      folder.draftIDs,
      depth: depth + 1,
      loadedDraftIDs: loadedDraftIDs,
      into: &entries
    )
    for child in folder.children {
      append(
        child,
        depth: depth + 1,
        expandedFolderIDs: expandedFolderIDs,
        loadedDraftIDs: loadedDraftIDs,
        into: &entries
      )
    }
  }

  private static func appendLoadedDrafts(
    _ draftIDs: [UUID],
    depth: Int,
    loadedDraftIDs: Set<UUID>,
    into entries: inout [WritingDraftFolderListEntry]
  ) {
    for draftID in draftIDs where loadedDraftIDs.contains(draftID) {
      entries.append(.draftEntry(draftID, depth: depth))
    }
  }
}
