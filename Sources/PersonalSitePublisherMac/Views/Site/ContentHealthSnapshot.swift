import Foundation
import PublishingWorkbenchCore

struct ContentHealthSnapshot: Sendable {
  var id: UUID
  var generatedAt: Date
  var profileID: UUID
  var profileName: String
  var publicRiskDraftSummaries: [DraftPreflightSummary]
  var aiFixQueueItems: [AIPublishingFixQueueItem]
  var sitePreflightIssues: [PreflightIssue]
  var contentHealthSummaries: [DraftPreflightSummary]
  var slugChangeImpacts: [UUID: SlugChangeImpact]
  var errorCount: Int
  var warningCount: Int
  var passingDraftCount: Int
  var suppressedIssues: [ContentHealthIssueOccurrence] = []
}
