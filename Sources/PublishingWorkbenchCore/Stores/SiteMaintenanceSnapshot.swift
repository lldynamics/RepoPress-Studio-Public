import Foundation

public struct SiteMaintenanceSnapshot {
  public let report: SiteMaintenanceReport
  public let profileID: UUID
  public let profileName: String
  public let draftCount: Int
  public let generatedAt: Date
  public let sourceVersion: Int
  public let refreshedAt: Date

  public init(
    report: SiteMaintenanceReport,
    profileID: UUID,
    profileName: String,
    draftCount: Int,
    sourceVersion: Int,
    generatedAt: Date? = nil,
    refreshedAt: Date = Date()
  ) {
    self.report = report
    self.profileID = profileID
    self.profileName = profileName
    self.draftCount = draftCount
    self.generatedAt = generatedAt ?? report.generatedAt
    self.sourceVersion = sourceVersion
    self.refreshedAt = refreshedAt
  }
}
