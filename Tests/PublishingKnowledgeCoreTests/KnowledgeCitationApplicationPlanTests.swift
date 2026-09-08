import Foundation
import XCTest

@testable import PublishingKnowledgeCore

final class KnowledgeCitationApplicationPlanTests: XCTestCase {
  func testSelectionPlanUsesOnlyProseCitationsAndAppendsDefinitionsToArticle() {
    let used = citation(id: "K1", title: "实际引用")
    let unused = citation(id: "K2", title: "未引用资料")
    let plan = KnowledgeCitationMarkdownService.applicationPlan(
      for: "替换后的结论 [K1]，`示例 [K2]`。",
      candidates: [used, unused],
      existingMarkdown: "原始正文。"
    )

    XCTAssertEqual(plan.referencedCitations, [used])
    XCTAssertTrue(
      plan.renderedContent.contains(KnowledgeCitationMarkdownService.footnoteReference(for: used)))
    XCTAssertTrue(plan.renderedContent.contains("`示例 [K2]`"))
    XCTAssertFalse(plan.renderedContent.contains("## 资料来源"))

    let selectedBody = "开头。\n\n\(plan.renderedContent)\n\n结尾。"
    let article = plan.appendingMissingDefinitions(to: selectedBody)
    XCTAssertTrue(article.contains(KnowledgeCitationMarkdownService.footnoteDefinition(for: used)))
    XCTAssertFalse(
      article.contains(KnowledgeCitationMarkdownService.footnoteDefinition(for: unused)))
    XCTAssertTrue(article.hasSuffix(KnowledgeCitationMarkdownService.footnoteDefinition(for: used)))
  }

  func testSelectionPlanReusesStableDefinitionAlreadyInArticle() {
    let citation = citation(id: "K1", title: "已有资料")
    let existing =
      "已有正文。\n\n## 资料来源\n\n\(KnowledgeCitationMarkdownService.footnoteDefinition(for: citation))"
    let plan = KnowledgeCitationMarkdownService.applicationPlan(
      for: "新段落 [K1]。",
      candidates: [citation],
      existingMarkdown: existing
    )

    XCTAssertEqual(plan.referencedCitations, [citation])
    XCTAssertTrue(plan.missingDefinitions.isEmpty)
    XCTAssertEqual(
      plan.appendingMissingDefinitions(to: existing + "\n\n" + plan.renderedContent),
      existing + "\n\n" + plan.renderedContent
    )
  }

  func testAppendingNoDefinitionsPreservesDestinationWhitespaceExactly() {
    let original = "\n  保留选区外的正文空白。  \n\n"
    let noDefinitions = KnowledgeCitationApplicationPlan(
      renderedContent: "已应用内容",
      referencedCitations: [],
      missingDefinitions: []
    )

    XCTAssertEqual(noDefinitions.appendingMissingDefinitions(to: original), original)
    XCTAssertEqual(
      KnowledgeCitationMarkdownService.appendingMissingDefinitions(
        to: original,
        citations: []
      ),
      original
    )
  }

  private func citation(id: String, title: String) -> KnowledgeCitation {
    KnowledgeCitation(
      id: id,
      documentID: UUID(),
      revisionID: UUID(),
      chunkID: UUID(),
      title: title,
      excerpt: "用于验证应用计划的本机资料。"
    )
  }
}
