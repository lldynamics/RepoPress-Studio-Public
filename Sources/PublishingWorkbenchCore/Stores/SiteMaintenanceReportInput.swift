import Foundation

/// Immutable inputs captured on the main actor before a maintenance report is
/// generated in the background.
struct SiteMaintenanceReportInput: Sendable {
  let drafts: [ArticleDraft]
  let profile: SiteProfile
  let releaseRecords: [ReleaseRecord]
  let maintenanceOperationRecords: [MaintenanceOperationRecord]
  let now: Date

  var signature: SiteMaintenanceReportInputSignature {
    SiteMaintenanceReportInputSignature(input: self)
  }
}

/// Value baseline used to reuse a current report and reject stale background
/// work. The exact generation time is reduced to a day because maintenance
/// aging and scheduling output only needs a new baseline when the day changes.
struct SiteMaintenanceReportInputSignature: Hashable, Sendable {
  private let drafts: [ArticleDraft]
  private let profile: SiteProfile
  private let releaseRecords: [ReleaseRecord]
  private let maintenanceOperationRecords: [MaintenanceOperationRecord]
  private let referenceDay: Date

  init(input: SiteMaintenanceReportInput) {
    self.drafts = input.drafts
    self.profile = input.profile
    self.releaseRecords = input.releaseRecords
    self.maintenanceOperationRecords = input.maintenanceOperationRecords
    self.referenceDay = Calendar(identifier: .gregorian).startOfDay(for: input.now)
  }
}
