import Combine
import Foundation

/// Owns the derived maintenance report lifecycle. The root store supplies the
/// current publishing inputs but does not expose this cache for mutation.
@MainActor
final class SiteMaintenanceStore: ObservableObject {
  @Published private(set) var snapshot: SiteMaintenanceSnapshot?
  @Published private(set) var snapshotVersion = 0
  private var sourceVersion = 0

  func invalidate() {
    sourceVersion += 1
    snapshotVersion += 1
  }

  func isStale() -> Bool {
    guard let snapshot else { return false }
    return snapshot.sourceVersion != sourceVersion
  }

  func replaceSnapshot(
    report: SiteMaintenanceReport,
    profileID: UUID,
    profileName: String,
    draftCount: Int
  ) {
    snapshot = SiteMaintenanceSnapshot(
      report: report,
      profileID: profileID,
      profileName: profileName,
      draftCount: draftCount,
      sourceVersion: sourceVersion
    )
    snapshotVersion += 1
  }
}
