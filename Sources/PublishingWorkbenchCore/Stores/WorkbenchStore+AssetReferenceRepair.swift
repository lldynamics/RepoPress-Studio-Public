import Foundation

public struct AssetReferenceRepairApplyResult: Hashable, Sendable {
  public let appliedDraftIDs: [UUID]
  public let persistenceSucceeded: Bool

  public init(appliedDraftIDs: [UUID], persistenceSucceeded: Bool) {
    self.appliedDraftIDs = appliedDraftIDs
    self.persistenceSucceeded = persistenceSucceeded
  }
}

extension WorkbenchStore {
  /// Applies reviewed token replacements through the draft/version/autosave
  /// pipeline. It intentionally does not write repository files directly.
  public func applyAssetReferenceRepairs(
    _ previews: [AssetReferenceRepairPreview],
    report: AssetResourceScanReport
  ) throws -> AssetReferenceRepairApplyResult {
    guard !previews.isEmpty else {
      return AssetReferenceRepairApplyResult(appliedDraftIDs: [], persistenceSucceeded: true)
    }
    flushDraftBodyEditorBuffers()
    let repairService = AssetReferenceRepairService()
    var updates: [UUID: ArticleDraft] = [:]
    for preview in previews {
      guard preview.profileID == activeProfile.id,
        preview.profileID == report.profileID,
        preview.repositoryRootPath == report.repositoryRootPath,
        preview.assetRootPath == report.assetRootPath
      else {
        throw AssetReferenceRepairError.stalePreview
      }
      guard let current = drafts.first(where: { $0.id == preview.draftID }) else {
        throw AssetReferenceRepairError.unavailableDraft
      }
      guard updates[preview.draftID] == nil else {
        // Multiple offsets in one body would need a descending-range batch
        // transform and a single shared baseline. Keep this first release
        // fail-closed until that transaction is explicitly designed.
        throw AssetReferenceRepairError.stalePreview
      }
      guard
        let replacement = report.assets.first(where: {
          $0.repositoryPath.normalizedRelativePath() == preview.replacementRepositoryPath
        })
      else { throw AssetReferenceRepairError.unsafeReplacement }
      try repairService.validate(replacement: replacement, report: report)
      try repairService.validatePreviewDiskBaseline(preview, report: report)
      updates[preview.draftID] = try repairService.applying(preview, to: current)
    }
    guard prepareRetainedBatchRecoveryVersions(for: Set(updates.keys)) != nil,
      flushPendingChanges()
    else { throw AssetReferenceRepairError.recoveryUnavailable }
    for preview in previews {
      guard let current = draft(for: preview.draftID) else {
        throw AssetReferenceRepairError.stalePreview
      }
      try repairService.validatePreviewDiskBaseline(preview, report: report)
      _ = try repairService.applying(preview, to: current)
    }
    guard applyImageBatchDraftUpdates(updates) else {
      throw AssetReferenceRepairError.stalePreview
    }
    let persisted = flushPendingChanges()
    return AssetReferenceRepairApplyResult(
      appliedDraftIDs: updates.keys.sorted { $0.uuidString < $1.uuidString },
      persistenceSucceeded: persisted
    )
  }
}
