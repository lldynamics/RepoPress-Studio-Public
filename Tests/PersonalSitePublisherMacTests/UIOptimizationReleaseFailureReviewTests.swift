import PublishingWorkbenchCore
import XCTest

@testable import PersonalSitePublisherMac

final class UIOptimizationReleaseFailureReviewTests: XCTestCase {
  func testReviewScopeDoesNotTurnSingleArticleFailureIntoWholeRepositoryPublish() {
    let record = ReleaseRecord(
      kind: .remotePublishFailure, title: "Failed", summary: "", draftID: UUID())
    XCTAssertEqual(ReleaseFailureReviewContext.initialScope(for: record), .currentArticle)
    let repositoryRecord = ReleaseRecord(kind: .remotePublishFailure, title: "Failed", summary: "")
    XCTAssertEqual(ReleaseFailureReviewContext.initialScope(for: repositoryRecord), .repository)
  }

  func testReviewRejectsChangedProfileBranchAndRepository() {
    var profile = SiteProfile(name: "Test", repoOwner: "owner", repoName: "site")
    let record = ReleaseRecord(
      kind: .remotePublishFailure, title: "Failed", summary: "",
      siteProfileID: profile.id, repoOwner: profile.repoOwner, repoName: profile.repoName,
      targetBranch: profile.branch.nilIfEmpty ?? "main"
    )
    XCTAssertTrue(ReleaseFailureReviewContext.canReview(record, profile: profile, drafts: []))
    profile.branch = "different-branch"
    XCTAssertFalse(ReleaseFailureReviewContext.canReview(record, profile: profile, drafts: []))
    profile.branch = record.targetBranch ?? "main"
    profile.repoName += "-different"
    XCTAssertFalse(ReleaseFailureReviewContext.canReview(record, profile: profile, drafts: []))
  }

  func testMissingArticleCannotFallBackToAnotherDraft() {
    let profile = SiteProfile(name: "Test")
    let record = ReleaseRecord(
      kind: .remotePublishFailure, title: "Failed", summary: "",
      siteProfileID: profile.id, draftID: UUID()
    )
    XCTAssertFalse(ReleaseFailureReviewContext.canReview(record, profile: profile, drafts: []))
  }

  func testBatchReviewAllowsExactlyTheHistoricalPublishableDraftIDs() {
    let profile = SiteProfile(name: "Test")
    let first = draft(profile: profile, title: "First")
    let second = draft(profile: profile, title: "Second")
    let record = batchFailureRecord(profile: profile, drafts: [first, second])
    let plan = batchPlan(profile: profile, drafts: [first, second])

    XCTAssertTrue(
      ReleaseFailureReviewContext.canReview(
        record, profile: profile, drafts: [first, second], batchPlan: plan
      )
    )
  }

  func testBatchReviewRejectsMissingCurrentPlanDraft() {
    let profile = SiteProfile(name: "Test")
    let first = draft(profile: profile, title: "First")
    let second = draft(profile: profile, title: "Second")
    let record = batchFailureRecord(profile: profile, drafts: [first, second])

    XCTAssertFalse(
      ReleaseFailureReviewContext.canReview(
        record, profile: profile, drafts: [first, second],
        batchPlan: batchPlan(profile: profile, drafts: [first])
      )
    )
  }

  func testBatchReviewRejectsReplacedCurrentPlanDraft() {
    let profile = SiteProfile(name: "Test")
    let first = draft(profile: profile, title: "First")
    let second = draft(profile: profile, title: "Second")
    let replacement = draft(profile: profile, title: "Replacement")
    let record = batchFailureRecord(profile: profile, drafts: [first, second])

    XCTAssertFalse(
      ReleaseFailureReviewContext.canReview(
        record, profile: profile, drafts: [first, second, replacement],
        batchPlan: batchPlan(profile: profile, drafts: [first, replacement])
      )
    )
  }

  func testBatchReviewRejectsExpandedCurrentPlan() {
    let profile = SiteProfile(name: "Test")
    let first = draft(profile: profile, title: "First")
    let second = draft(profile: profile, title: "Second")
    let replacement = draft(profile: profile, title: "Replacement")
    let record = batchFailureRecord(profile: profile, drafts: [first, second])

    XCTAssertFalse(
      ReleaseFailureReviewContext.canReview(
        record, profile: profile, drafts: [first, second, replacement],
        batchPlan: batchPlan(profile: profile, drafts: [first, second, replacement])
      )
    )
  }

  func testBatchReviewRejectsMissingHistoricalDraft() {
    let profile = SiteProfile(name: "Test")
    let first = draft(profile: profile, title: "First")
    let second = draft(profile: profile, title: "Second")
    let record = batchFailureRecord(profile: profile, drafts: [first, second])

    XCTAssertFalse(
      ReleaseFailureReviewContext.canReview(
        record, profile: profile, drafts: [first],
        batchPlan: batchPlan(profile: profile, drafts: [first, second])
      )
    )
  }

  func testBatchReviewRejectsDifferentPlanProfile() {
    let profile = SiteProfile(name: "Test")
    let otherProfile = SiteProfile(name: "Other")
    let first = draft(profile: profile, title: "First")
    let second = draft(profile: profile, title: "Second")
    let record = batchFailureRecord(profile: profile, drafts: [first, second])

    XCTAssertFalse(
      ReleaseFailureReviewContext.canReview(
        record, profile: profile, drafts: [first, second],
        batchPlan: batchPlan(profile: otherProfile, drafts: [first, second])
      )
    )
  }

  private func batchFailureRecord(profile: SiteProfile, drafts: [ArticleDraft]) -> ReleaseRecord {
    ReleaseRecord(
      kind: .remotePublishFailure,
      title: "Failed",
      summary: "",
      siteProfileID: profile.id,
      batchItems: drafts.map {
        ReleaseRecordBatchItem(
          draftID: $0.id,
          draftTitle: $0.title,
          markdownPath: "content/posts/\($0.slug).md",
          changedPaths: ["content/posts/\($0.slug).md"]
        )
      }
    )
  }

  private func draft(profile: SiteProfile, title: String) -> ArticleDraft {
    ArticleDraft(siteProfileID: profile.id, title: title, slug: title.lowercased())
  }

  private func batchPlan(profile: SiteProfile, drafts: [ArticleDraft]) -> BatchPublishPlan {
    BatchPublishPlan(
      profileID: profile.id,
      siteName: profile.name,
      items: drafts.map { draft in
        let path = "content/posts/\(draft.slug).md"
        let package = PublishPackage(
          draftID: draft.id,
          title: draft.title,
          markdownPath: path,
          files: [PublishPackageFile(kind: .markdown, repositoryPath: path, content: "body")],
          commitMessage: "Publish \(draft.title)",
          reviewBranchName: "publish/test",
          reviewTitle: "Publish \(draft.title)",
          reviewChecklist: []
        )
        let preview = LocalPublishPreview(
          package: package,
          fileDiffs: [PublishFileDiff(path: path, kind: .markdown, status: .modified)],
          issues: []
        )
        return BatchPublishPlanItem(
          draftID: draft.id,
          draftTitle: draft.title,
          markdownPath: path,
          readiness: .ready,
          package: package,
          preview: preview,
          preflightIssues: []
        )
      }
    )
  }
}
