import Combine
import Foundation

/// Owns the derived maintenance report lifecycle. The root store supplies the
/// current publishing inputs but does not expose this cache for mutation.
@MainActor
final class SiteMaintenanceStore: ObservableObject {
  @Published private(set) var snapshot: SiteMaintenanceSnapshot?
  @Published private(set) var snapshotVersion = 0
  @Published private(set) var isRefreshing = false
  private var sourceVersion = 0
  private var inputSignature: SiteMaintenanceReportInputSignature?

  func invalidate() {
    sourceVersion += 1
    snapshotVersion += 1
  }

  func isStale() -> Bool {
    guard let snapshot else { return false }
    return snapshot.sourceVersion != sourceVersion
  }

  func hasCurrentSnapshot(for signature: SiteMaintenanceReportInputSignature) -> Bool {
    snapshot != nil && !isStale() && inputSignature == signature
  }

  func setRefreshing(_ value: Bool) {
    isRefreshing = value
  }

  func relatedArticleSuggestions(
    for draftID: UUID,
    profileID: UUID,
    limit: Int
  ) -> [SiteRelationSuggestion] {
    guard !isStale(), snapshot?.profileID == profileID else { return [] }
    return snapshot?.relatedArticleSuggestions(for: draftID, limit: limit) ?? []
  }

  func replaceSnapshot(
    report: SiteMaintenanceReport,
    profileID: UUID,
    profileName: String,
    draftCount: Int,
    inputSignature: SiteMaintenanceReportInputSignature
  ) {
    snapshot = SiteMaintenanceSnapshot(
      report: report,
      profileID: profileID,
      profileName: profileName,
      draftCount: draftCount,
      sourceVersion: sourceVersion
    )
    self.inputSignature = inputSignature
    snapshotVersion += 1
  }
}
