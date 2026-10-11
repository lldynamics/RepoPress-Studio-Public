import Foundation

/// Process-local preflight result and the inexpensive input identity which
/// was validated before installation. Repository publications have a second
/// generation because detail updates can retain the scan's report revision.
struct DraftPreflightSnapshot: Equatable, Sendable {
  let requestKey: DraftScopedPreflightRequestKey
  let draftInputGeneration: UInt64
  let repositoryInputGeneration: UInt64
  let result: DraftPreflightResult

  func matches(_ current: DraftScopedPreflightRequestKey) -> Bool {
    // Word-count backfills advance the broad mutation revision but are not
    // preflight inputs. The session's input generation covers all actual
    // draft/sibling changes without scanning those siblings during a read.
    requestKey.draftID == current.draftID
      && requestKey.bodyRevision == current.bodyRevision
      && !current.hasPendingBody
      && requestKey.linkAuditInputGeneration == current.linkAuditInputGeneration
      && requestKey.profile == current.profile
      && requestKey.repositoryReportRevision == current.repositoryReportRevision
  }
}
