import Foundation

/// A cheap, in-memory identity for a window's preflight task. In particular,
/// constructing this key never scans the repository or audits Markdown links.
public struct DraftScopedPreflightRequestKey: Equatable, Sendable {
  let draftID: UUID
  let bodyRevision: UInt64
  let hasPendingBody: Bool
  let draftMutationRevision: UInt64
  let linkAuditInputGeneration: UInt64
  let profile: SiteProfile
  let repositoryReportRevision: UUID
}

extension WorkbenchStore {
  public func draftScopedPreflightRequestKey(for draftID: UUID) -> DraftScopedPreflightRequestKey? {
    guard let draft = draft(for: draftID) else { return nil }
    let buffer = draftBodyEditorBuffer(for: draftID)
    let profile = profile(for: draft)
    return DraftScopedPreflightRequestKey(
      draftID: draftID,
      bodyRevision: buffer.revision,
      hasPendingBody: buffer.isDirty,
      draftMutationRevision: draftMutationRevision,
      linkAuditInputGeneration: siteLinkAuditSnapshotStore.inputGeneration,
      profile: profile,
      // The revision is cheap to compare. `runPreflight(for:)` captures and
      // validates the report itself after asynchronous work completes.
      repositoryReportRevision: repositoryStore.repositoryLineDiffReportRevision
    )
  }
}
