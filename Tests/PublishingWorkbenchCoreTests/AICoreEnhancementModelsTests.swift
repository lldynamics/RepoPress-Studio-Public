import Foundation
import XCTest

@testable import PublishingWorkbenchCore

final class AICoreEnhancementModelsTests: XCTestCase {
  func testContextSummaryNamesEverySupportedReferenceWithoutEmbeddingContent() {
    let draftID = UUID()
    let duplicateID = UUID()
    let references = [
      AIContextReference(
        id: duplicateID,
        kind: .currentSelection,
        resourceID: draftID.uuidString,
        sourceRange: AIStructuredEditSourceRange(location: 3, length: 8),
        characterCount: 8
      ),
      AIContextReference(
        id: duplicateID,
        kind: .currentSelection,
        resourceID: draftID.uuidString,
        sourceRange: AIStructuredEditSourceRange(location: 3, length: 8),
        characterCount: 8
      ),
      .currentArticle(draftID: draftID, title: "文章甲", characterCount: 100),
      .specifiedArticle(draftID: UUID(), title: "文章乙", characterCount: 200),
      .knowledgeEntry(documentID: UUID(), title: "写作规范", characterCount: 30),
      .publishCheck(draftID: draftID, issueCount: 2, characterCount: 20),
    ]

    let summary = AIContextTransmissionSummaryService.make(references: references)

    XCTAssertEqual(summary.items.count, 5)
    XCTAssertEqual(summary.totalCharacterCount, 358)
    XCTAssertTrue(summary.displayText.contains("当前选区"))
    XCTAssertTrue(summary.displayText.contains("当前文章：文章甲"))
    XCTAssertTrue(summary.displayText.contains("指定文章：文章乙"))
    XCTAssertTrue(summary.displayText.contains("资料条目：写作规范"))
    XCTAssertTrue(summary.displayText.contains("发布检查：2 项"))
    XCTAssertFalse(summary.displayText.contains("这是一段不应出现的正文"))
  }

  func testTranslationPlanCreatesLinkedUnpublishedDraftWithoutMutatingSource() throws {
    let profile = SiteProfile.defaultProfile
    let attachment = DraftAttachment(
      originalFilename: "cover.png",
      relativePublishPath: "images/cover.png",
      repositoryPath: "static/images/cover.png"
    )
    let source = ArticleDraft(
      siteProfileID: profile.id,
      title: "原文",
      slug: "source",
      tags: ["工具"],
      categories: ["写作"],
      authors: ["作者"],
      draft: false,
      visibility: .public,
      summary: "原摘要",
      coverAttachmentID: attachment.id,
      bodyMarkdown: "# 原文\n\n![封面](images/cover.png)",
      attachments: [attachment],
      status: .published,
      repositoryPath: "content/source.md",
      repositorySHA: "remote-sha",
      repositoryImportFingerprint: "import-fingerprint"
    )
    let originalSource = source
    let destinationID = UUID()
    let plan = try AITranslationDraftPlanningService.plan(
      source: source,
      targetLanguageCode: "EN_us",
      translatedTitle: "Source",
      translatedSummary: "Summary",
      translatedBodyMarkdown: "# Source\n\n![Cover](images/cover.png)",
      destinationDraftID: destinationID,
      plannedAt: Date(timeIntervalSince1970: 2_000)
    )

    XCTAssertEqual(source, originalSource)
    XCTAssertEqual(plan.sourceDraftID, source.id)
    XCTAssertEqual(plan.targetLanguageCode, "en-us")
    XCTAssertEqual(plan.translatedDraft.id, destinationID)
    XCTAssertNotEqual(plan.translatedDraft.id, source.id)
    XCTAssertEqual(plan.translatedDraft.slug, "source-en-us")
    XCTAssertTrue(plan.translatedDraft.draft)
    XCTAssertEqual(plan.translatedDraft.status, .draft)
    XCTAssertNil(plan.translatedDraft.repositoryPath)
    XCTAssertNil(plan.translatedDraft.repositorySHA)
    XCTAssertNil(plan.translatedDraft.repositoryImportFingerprint)
    XCTAssertEqual(plan.translatedDraft.attachments, source.attachments)
    XCTAssertEqual(plan.translatedDraft.coverAttachmentID, attachment.id)
    XCTAssertEqual(plan.link.sourceDraftID, source.id)
    XCTAssertEqual(plan.link.translatedDraftID, destinationID)

    let materialized = try AITranslationDraftPlanningService.materialize(
      plan,
      currentSource: source
    )
    XCTAssertEqual(materialized, plan.translatedDraft)
  }

  func testTranslationPlanRejectsStaleSourceAndSourceIdentityReuse() throws {
    let profile = SiteProfile.defaultProfile
    let source = ArticleDraft(
      siteProfileID: profile.id,
      title: "原文",
      slug: "source",
      bodyMarkdown: "需要翻译的正文"
    )
    XCTAssertThrowsError(
      try AITranslationDraftPlanningService.plan(
        source: source,
        targetLanguageCode: "en",
        translatedTitle: "Source",
        translatedSummary: "",
        translatedBodyMarkdown: "Translated body",
        destinationDraftID: source.id
      )
    ) { error in
      XCTAssertEqual(
        error as? AITranslationDraftPlanningError,
        .destinationReusesSourceIdentity
      )
    }

    let plan = try AITranslationDraftPlanningService.plan(
      source: source,
      targetLanguageCode: "en",
      translatedTitle: "Source",
      translatedSummary: "",
      translatedBodyMarkdown: "Translated body"
    )
    var changedSource = source
    changedSource.bodyMarkdown = "用户已经修改正文"

    XCTAssertThrowsError(
      try AITranslationDraftPlanningService.materialize(
        plan,
        currentSource: changedSource
      )
    ) { error in
      XCTAssertEqual(
        error as? AITranslationDraftPlanningError,
        .sourceDraftChanged
      )
    }
  }
}
