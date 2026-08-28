import Foundation

/// Stable identity for one site-wide link projection. The monotonic draft
/// revision avoids hashing every Markdown body merely to discover that an
/// existing report is still current.
struct SiteLinkAuditSnapshotKey: Hashable, Sendable {
  let profile: SiteProfile
  let draftMutationRevision: UInt64
  let draftIDs: [UUID]
  let bodyRevisions: [DraftExecutionContext]

  init(
    profile: SiteProfile,
    draftMutationRevision: UInt64,
    drafts: [ArticleDraft],
    bodyRevisions: [DraftExecutionContext]
  ) {
    self.profile = profile
    self.draftMutationRevision = draftMutationRevision
    draftIDs = drafts.map(\.id).sorted { $0.uuidString < $1.uuidString }
    self.bodyRevisions = bodyRevisions.sorted {
      $0.draftID.uuidString < $1.draftID.uuidString
    }
  }
}

/// Main-actor cache shared by preflight, Content Health, Slug impact and site
/// maintenance. Only local link resolution is cached here; explicit online
/// probes remain an on-demand operation and never replace this deterministic
/// snapshot.
@MainActor
final class SiteLinkAuditSnapshotStore {
  private var key: SiteLinkAuditSnapshotKey?
  private var report: SiteLinkAuditReport?
  private(set) var replacementCount = 0

  func report(for key: SiteLinkAuditSnapshotKey) -> SiteLinkAuditReport? {
    guard self.key == key else { return nil }
    return report
  }

  func replace(_ report: SiteLinkAuditReport, for key: SiteLinkAuditSnapshotKey) {
    self.key = key
    self.report = report
    replacementCount += 1
  }

  func invalidate() {
    key = nil
    report = nil
  }
}
