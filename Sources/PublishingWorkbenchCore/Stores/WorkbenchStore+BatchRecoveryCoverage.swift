import Foundation

/// Uses complete snapshots (except edit timestamps) so recovery coverage cannot
/// be inferred from a count that stays constant at the retention limit.
enum BatchRecoveryCoverage {
  static func count(drafts: [ArticleDraft], versions: [DraftVersionSnapshot]) -> Int {
    drafts.filter { draft in
      versions.contains { version in
        guard version.draftID == draft.id else { return false }
        var original = draft
        var captured = version.draft
        original.updatedAt = .distantPast
        captured.updatedAt = .distantPast
        return original == captured
      }
    }.count
  }
}

extension WorkbenchStore {
  /// Returns nil without changing the retained version collection if its limit
  /// would evict any article's recovery point before this batch starts.
  func prepareRetainedBatchRecoveryVersions(for draftIDs: Set<UUID>) -> Int? {
    let originals = drafts.filter { draftIDs.contains($0.id) }
    guard originals.count == draftIDs.count,
      originals.count <= DraftLifecycleService.maximumTotalVersions
    else { return nil }
    let previousVersions = publishingStore.draftVersions
    _ = recordVersionsBeforeBatchProcessing(draftIDs: draftIDs, persisting: false)
    let covered = BatchRecoveryCoverage.count(
      drafts: originals, versions: publishingStore.draftVersions)
    guard covered == originals.count else {
      publishingStore.draftVersions = previousVersions
      return nil
    }
    save()
    return covered
  }
}
