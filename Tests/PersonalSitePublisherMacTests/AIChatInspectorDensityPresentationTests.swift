import XCTest

@testable import PersonalSitePublisherMac

final class AIChatInspectorDensityPresentationTests: XCTestCase {
  func testContextControlSummaryNamesCurrentArticleAndKnowledgePolicy() {
    let summary = AIChatInspectorDensityPresentation.compactContextSummary(
      mode: .site,
      draftTitle: "  发布方案  ",
      explicitReferenceCount: 0,
      knowledgeTitle: "仅固定资料",
      agentTitle: ""
    )

    XCTAssertEqual(summary, "当前文章：发布方案 · 资料库：仅固定资料")
  }

  func testContextControlSummaryDoesNotInventArticleWhenNoneIsSelected() {
    let summary = AIChatInspectorDensityPresentation.compactContextSummary(
      mode: .site,
      draftTitle: " \n ",
      explicitReferenceCount: 0,
      knowledgeTitle: "关闭资料库",
      agentTitle: ""
    )

    XCTAssertEqual(summary, "当前文章：未选择文章 · 资料库：关闭资料库")
  }

  func testCompactSummaryKeepsGeneralChatArticleBoundaryAndManualReferenceCount() {
    let summary = AIChatInspectorDensityPresentation.compactContextSummary(
      mode: .general,
      draftTitle: "不应出现的文章",
      explicitReferenceCount: 2,
      knowledgeTitle: "自动检索",
      agentTitle: "仅问答"
    )

    XCTAssertEqual(summary, "通用聊天：不读取当前文章 · 2 项手动引用 · 资料库：自动检索")
  }

  func testGeneralChatWithoutReferencesDoesNotShowAnEmptyReferenceCount() {
    let summary = AIChatInspectorDensityPresentation.compactContextSummary(
      mode: .general,
      draftTitle: "不应出现的文章",
      explicitReferenceCount: 0,
      knowledgeTitle: "自动检索",
      agentTitle: ""
    )

    XCTAssertEqual(summary, "通用聊天：不读取当前文章 · 资料库：自动检索")
  }
}
