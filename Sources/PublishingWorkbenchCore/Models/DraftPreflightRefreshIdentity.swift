import Foundation

/// Cheap identity for a window's preflight refresh. Derived word-count
/// publications do not change it; body/sibling and repository publications do.
public struct DraftPreflightRefreshIdentity: Equatable, Sendable {
  public let requestKey: DraftScopedPreflightRequestKey
  public let draftInputGeneration: UInt64
  public let repositoryInputGeneration: UInt64
}

extension WorkbenchStore {
  public func draftPreflightRefreshIdentity(for draftID: UUID) -> DraftPreflightRefreshIdentity? {
    configureDraftPreflightInputObservationIfNeeded()
    guard let key = draftScopedPreflightRequestKey(for: draftID) else { return nil }
    return DraftPreflightRefreshIdentity(
      requestKey: DraftScopedPreflightRequestKey(
        draftID: key.draftID,
        bodyRevision: key.bodyRevision,
        hasPendingBody: key.hasPendingBody,
        draftMutationRevision: 0,
        linkAuditInputGeneration: key.linkAuditInputGeneration,
        profile: key.profile,
        repositoryReportRevision: key.repositoryReportRevision
      ),
      draftInputGeneration: publishingStore.publishSession.draftPreflightDraftInputGeneration,
      repositoryInputGeneration:
        publishingStore.publishSession.draftPreflightRepositoryInputGeneration
    )
  }
}
