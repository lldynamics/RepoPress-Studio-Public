import Foundation

/// Stable identity for one site-wide link projection. The generation advances
/// synchronously when link-audit inputs invalidate, so unrelated derived draft
/// mutations such as an asynchronous word-count backfill do not discard a
/// report that was calculated from the still-current Markdown and metadata.
struct SiteLinkAuditSnapshotKey: Hashable, Sendable {
  let profile: SiteProfile
  let inputGeneration: UInt64
  let draftIDs: [UUID]
  let bodyRevisions: [DraftExecutionContext]

  init(
    profile: SiteProfile,
    inputGeneration: UInt64,
    drafts: [ArticleDraft],
    bodyRevisions: [DraftExecutionContext]
  ) {
    self.profile = profile
    self.inputGeneration = inputGeneration
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
  private(set) var inputGeneration: UInt64 = 0
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
    inputGeneration &+= 1
    key = nil
    report = nil
  }
}
