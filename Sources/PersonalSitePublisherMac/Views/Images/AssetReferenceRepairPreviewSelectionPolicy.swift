import Foundation

/// Keeps pending repair previews compatible with the current single-draft
/// repair transaction. Draft identity, rather than a display path, decides
/// which earlier preview must be replaced.
struct AssetReferenceRepairPreviewSelectionCandidate: Hashable, Identifiable {
  let id: UUID
  let draftID: UUID
  let sourcePath: String
}

struct AssetReferenceRepairPreviewReplacement: Equatable {
  let removedPreviewIDs: Set<UUID>
  let selectedPreviewIDs: Set<UUID>
}

enum AssetReferenceRepairPreviewSelectionPolicy {
  static func replacing(
    preview: AssetReferenceRepairPreviewSelectionCandidate,
    existingPreviews: [AssetReferenceRepairPreviewSelectionCandidate],
    selectedPreviewIDs: Set<UUID>
  ) -> AssetReferenceRepairPreviewReplacement {
    let removedPreviewIDs = Set(
      existingPreviews
        .filter { $0.draftID == preview.draftID }
        .map(\.id)
    )
    var nextSelectedPreviewIDs = selectedPreviewIDs
    nextSelectedPreviewIDs.subtract(removedPreviewIDs)
    nextSelectedPreviewIDs.insert(preview.id)
    return AssetReferenceRepairPreviewReplacement(
      removedPreviewIDs: removedPreviewIDs,
      selectedPreviewIDs: nextSelectedPreviewIDs
    )
  }
}
