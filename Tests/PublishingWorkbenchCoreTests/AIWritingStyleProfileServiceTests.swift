import XCTest

@testable import PublishingWorkbenchCore

final class AIWritingStyleProfileServiceTests: XCTestCase {
  func testContextAcceptsOnlySameSitePublicArticleAndBoundsBody() throws {
    let profileID = UUID()
    let publicDraft = ArticleDraft(
      siteProfileID: profileID,
      title: "公开范例",
      draft: false,
      visibility: .public,
      bodyMarkdown: String(repeating: "公开正文", count: 1_000)
    )
    let privateDraft = ArticleDraft(
      siteProfileID: profileID,
      title: "私密范例",
      draft: false,
      visibility: .private,
      bodyMarkdown: "不能发送"
    )
    let service = AIWritingStyleProfileService()

    let context = try service.exemplarContext(
      profileID: profileID,
      drafts: [publicDraft, privateDraft],
      selectedArticleIDs: [publicDraft.id]
    )

    XCTAssertEqual(context.articleIDs, [publicDraft.id])
    XCTAssertFalse(context.text.contains("私密范例"))
    XCTAssertLessThanOrEqual(context.text.count, AIWritingStyleExemplarContext.maximumCharacters)
    XCTAssertTrue(context.wasTruncated)
    XCTAssertThrowsError(
      try service.exemplarContext(
        profileID: profileID,
        drafts: [publicDraft, privateDraft],
        selectedArticleIDs: [privateDraft.id]
      )
    )
  }

  func testContextCapsHugeTitleAndTotalTextExactly() throws {
    let profileID = UUID()
    let draft = ArticleDraft(
      siteProfileID: profileID,
      title: String(repeating: "标题", count: 100_000),
      draft: false,
      visibility: .public,
      bodyMarkdown: String(repeating: "正文", count: 100_000)
    )

    let context = try AIWritingStyleProfileService().exemplarContext(
      profileID: profileID,
      drafts: [draft],
      selectedArticleIDs: [draft.id]
    )

    XCTAssertLessThanOrEqual(context.text.count, AIWritingStyleExemplarContext.maximumCharacters)
    XCTAssertTrue(context.wasTruncated)
  }

  func testContextRejectsMoreThanMaximumSelectedExamples() {
    let profileID = UUID()
    let drafts = (0...AIWritingStyleConfig.maximumExemplarCount).map { index in
      ArticleDraft(
        siteProfileID: profileID,
        title: "范例\(index)",
        draft: false,
        visibility: .public,
        bodyMarkdown: "正文"
      )
    }

    XCTAssertThrowsError(
      try AIWritingStyleProfileService().exemplarContext(
        profileID: profileID,
        drafts: drafts,
        selectedArticleIDs: drafts.map(\.id)
      )
    ) { error in
      XCTAssertEqual(error as? AIWritingStyleProfileError, .tooManyExemplars)
    }
  }

  func testPreviewUsesAIResponseAndKeepsOnlyBoundedSiteProfileFields() throws {
    let profileID = UUID()
    let draft = ArticleDraft(
      siteProfileID: profileID,
      title: "范例",
      draft: false,
      visibility: .public,
      bodyMarkdown: "正文"
    )
    let service = AIWritingStyleProfileService()
    let context = try service.exemplarContext(
      profileID: profileID,
      drafts: [draft],
      selectedArticleIDs: [draft.id]
    )
    let preview = try service.preview(
      response: """
        {"tone":"克制直接","audience":"独立开发者","summaryGuidance":"先给结论","tagGuidance":"使用稳定术语","seoGuidance":"标题明确","preferredTerminology":["RepoPress"],"avoidedExpressions":["赋能"]}
        """,
      baseline: .default,
      context: context
    )

    XCTAssertEqual(preview.profileID, profileID)
    XCTAssertEqual(preview.exemplarArticleIDs, [draft.id])
    XCTAssertEqual(preview.style.preferredTerminology, ["RepoPress"])
    XCTAssertEqual(preview.style.avoidedExpressions, ["赋能"])
    XCTAssertTrue(preview.style.promptInstructions.contains("优先使用术语：RepoPress"))
  }

  func testPreviewCannotApplyWhenSelectedArticleBecomesPrivate() throws {
    let profile = SiteProfile(name: "站点")
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "范例",
      draft: false,
      visibility: .public,
      bodyMarkdown: "正文"
    )
    let service = AIWritingStyleProfileService()
    let context = try service.exemplarContext(
      profileID: profile.id,
      drafts: [draft],
      selectedArticleIDs: [draft.id]
    )
    let preview = try service.preview(
      response: "{\"tone\":\"直接\"}",
      baseline: profile.resolvedAIWritingStyle,
      context: context
    )
    var privateDraft = draft
    privateDraft.visibility = .private

    XCTAssertNil(service.validatedPreview(preview, profile: profile, drafts: [privateDraft]))
  }

  func testPreviewRejectsEmptyResponseAndBecomesStaleAfterBodyOrStyleChange() throws {
    var profile = SiteProfile(name: "站点")
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "范例",
      draft: false,
      visibility: .public,
      bodyMarkdown: "原正文"
    )
    let service = AIWritingStyleProfileService()
    let context = try service.exemplarContext(
      profileID: profile.id,
      drafts: [draft],
      selectedArticleIDs: [draft.id]
    )
    XCTAssertThrowsError(
      try service.preview(
        response: "{}", baseline: profile.resolvedAIWritingStyle, context: context)
    )
    let preview = try service.preview(
      response: "{\"tone\":\"直接\"}",
      baseline: profile.resolvedAIWritingStyle,
      context: context
    )
    var changedBody = draft
    changedBody.bodyMarkdown = "新正文"
    XCTAssertNil(service.validatedPreview(preview, profile: profile, drafts: [changedBody]))

    profile.resolvedAIWritingStyle.tone = "用户已手动修改"
    XCTAssertNil(service.validatedPreview(preview, profile: profile, drafts: [draft]))
  }

  func testPreviewMergesExistingPersonalTerminology() throws {
    let profileID = UUID()
    let draft = ArticleDraft(
      siteProfileID: profileID,
      title: "范例",
      draft: false,
      visibility: .public,
      bodyMarkdown: "正文"
    )
    let baseline = AIWritingStyleConfig(
      preferredTerminology: ["RepoPress Studio"],
      avoidedExpressions: ["赋能"]
    )
    let context = try AIWritingStyleProfileService().exemplarContext(
      profileID: profileID,
      drafts: [draft],
      selectedArticleIDs: [draft.id]
    )
    let preview = try AIWritingStyleProfileService().preview(
      response: "{\"tone\":\"直接\",\"preferredTerminology\":[],\"avoidedExpressions\":[]}",
      baseline: baseline,
      context: context
    )

    XCTAssertEqual(preview.style.preferredTerminology, ["RepoPress Studio"])
    XCTAssertEqual(preview.style.avoidedExpressions, ["赋能"])
  }
}
