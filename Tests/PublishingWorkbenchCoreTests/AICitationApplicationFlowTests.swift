import Foundation
import XCTest

@testable import PublishingWorkbenchCore

final class AICitationApplicationFlowTests: XCTestCase {
  func testSameReplyProducesStableDefinitionsForAppendAndSelectionReplacement() throws {
    let citation = KnowledgeCitation(
      id: "K1",
      documentID: UUID(),
      revisionID: UUID(),
      chunkID: UUID(),
      title: "固定资料",
      excerpt: "用于支持同一条 AI 回复。"
    )
    let reply = "AI 结论 [K1]。"
    let appendDraft = ArticleDraft(siteProfileID: UUID(), title: "追加", bodyMarkdown: "已有正文。")
    let selectionPrefix = "\n  开头。  \n\n"
    let selectionSuffix = "\n\n结尾。  \n"
    let selectionDraft = ArticleDraft(
      siteProfileID: UUID(),
      title: "替换",
      bodyMarkdown: selectionPrefix
        + KnowledgeCitationMarkdownService.footnoteDefinition(for: citation)
        + selectionSuffix
    )
    let appendPlan = KnowledgeCitationMarkdownService.applicationPlan(
      for: reply,
      candidates: [citation],
      existingMarkdown: appendDraft.bodyMarkdown
    )
    let selectionPlan = KnowledgeCitationMarkdownService.applicationPlan(
      for: reply,
      candidates: [citation],
      existingMarkdown: selectionDraft.bodyMarkdown
    )

    let appended = try XCTUnwrap(
      AIPublishingChatDraftApplicationService.applyAssistantContent(
        appendPlan.appendingMissingDefinitions(to: appendPlan.renderedContent),
        to: appendDraft,
        mode: .appendToBody
      )
    )
    let selectionRange = (selectionDraft.bodyMarkdown as NSString).range(
      of: KnowledgeCitationMarkdownService.footnoteDefinition(for: citation)
    )
    let selected = try XCTUnwrap(
      AIPublishingChatDraftApplicationService.applyAssistantContent(
        selectionPlan.renderedContent,
        to: selectionDraft,
        mode: .replaceSelection,
        selectionRange: selectionRange
      )
    )
    var selectedWithDefinitions = selected.draft
    selectedWithDefinitions.bodyMarkdown =
      KnowledgeCitationMarkdownService.appendingMissingDefinitions(
        to: selectedWithDefinitions.bodyMarkdown,
        citations: selectionPlan.referencedCitations
      )

    for draft in [appended.draft, selectedWithDefinitions] {
      XCTAssertTrue(
        draft.bodyMarkdown.contains(
          KnowledgeCitationMarkdownService.footnoteReference(for: citation)))
      XCTAssertTrue(
        draft.bodyMarkdown.contains(
          KnowledgeCitationMarkdownService.footnoteDefinition(for: citation)))
    }
    XCTAssertTrue(
      selectedWithDefinitions.bodyMarkdown.hasPrefix(
        selectionPrefix + selectionPlan.renderedContent + selectionSuffix
      ),
      "Replacing a definition must preserve the original body whitespace before the newly appended definition."
    )
    XCTAssertEqual(appendPlan.referencedCitations, [citation])
    XCTAssertEqual(selectionPlan.referencedCitations, [citation])
  }
}
