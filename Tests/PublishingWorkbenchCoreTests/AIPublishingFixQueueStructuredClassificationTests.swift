import XCTest
@testable import PublishingWorkbenchCore

final class AIPublishingFixQueueStructuredClassificationTests: XCTestCase {
  func testClassifiesMetadataIssuesByStructuredFieldRegardlessOfLocalizedTitle() throws {
    let profile = SiteProfile.defaultProfile
    let summaryDraft = makeCompleteDraft(profile: profile, slug: "summary-field")
    let coverDraft = makeCompleteDraft(profile: profile, slug: "cover-field")
    let summaries = [
      summary(
        for: summaryDraft,
        profile: profile,
        issue: PreflightIssue(
          severity: .warning,
          title: "Localized diagnostic A",
          message: "Localized detail A",
          field: "summary"
        )
      ),
      summary(
        for: coverDraft,
        profile: profile,
        issue: PreflightIssue(
          severity: .warning,
          title: "Localized diagnostic B",
          message: "Localized detail B",
          field: "cover"
        )
      ),
    ]

    let items = AIPublishingFixQueueService().items(
      drafts: [summaryDraft, coverDraft],
      profile: profile,
      summaries: summaries
    )
    let summaryItem = try XCTUnwrap(items.first { $0.draftID == summaryDraft.id })
    let coverItem = try XCTUnwrap(items.first { $0.draftID == coverDraft.id })

    XCTAssertTrue(summaryItem.needsSummary)
    XCTAssertEqual(summaryItem.recommendedAction, .suggestSummary)
    XCTAssertFalse(coverItem.needsSummary)
    XCTAssertFalse(coverItem.needsTags)
    XCTAssertEqual(coverItem.recommendedAction, .draftFrontMatterPack)
  }

  func testLocalizedKeywordsWithoutStructuredFieldDoNotEnterQueue() {
    let profile = SiteProfile.defaultProfile
    let draft = makeCompleteDraft(profile: profile, slug: "localized-copy-only")
    let summary = summary(
      for: draft,
      profile: profile,
      issue: PreflightIssue(
        severity: .warning,
        title: "摘要 / Tags / 标题 / 封面",
        message: "Localized detail"
      )
    )

    let items = AIPublishingFixQueueService().items(
      drafts: [draft],
      profile: profile,
      summaries: [summary]
    )

    XCTAssertTrue(items.isEmpty)
  }

  private func makeCompleteDraft(profile: SiteProfile, slug: String) -> ArticleDraft {
    ArticleDraft(
      siteProfileID: profile.id,
      title: "Complete metadata",
      slug: slug,
      tags: ["Testing"],
      summary: "An existing summary",
      bodyMarkdown: "This body is intentionally long enough to enter the structured AI fix queue."
    )
  }

  private func summary(
    for draft: ArticleDraft,
    profile: SiteProfile,
    issue: PreflightIssue
  ) -> DraftPreflightSummary {
    DraftPreflightSummary(
      draftID: draft.id,
      draftTitle: draft.title,
      markdownPath: profile.markdownPath(for: draft),
      issues: [issue]
    )
  }
}
