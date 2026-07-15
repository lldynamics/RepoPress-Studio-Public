import Foundation

public struct SiteMaintenanceSnapshot {
  public let report: SiteMaintenanceReport
  public let profileID: UUID
  public let profileName: String
  public let draftCount: Int
  public let generatedAt: Date
  public let sourceVersion: Int
  public let refreshedAt: Date
  private let relationSuggestionsByDraftID: [UUID: [SiteRelationSuggestion]]

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
    self.relationSuggestionsByDraftID = Dictionary(
      grouping: report.relationSuggestions,
      by: \.sourceDraftID
    )
  }

  public func relatedArticleSuggestions(
    for draftID: UUID,
    limit: Int = 5
  ) -> [SiteRelationSuggestion] {
    guard limit > 0 else { return [] }
    return Array(relationSuggestionsByDraftID[draftID, default: []].prefix(limit))
  }
}
