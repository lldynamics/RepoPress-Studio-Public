import XCTest
@testable import PersonalSitePublisherMac

final class AIChatInspectorDensityPresentationTests: XCTestCase {
  func testCollapsedInspectorShowsOnlyOneLineSummaryAndNoQuickActionBand() {
    let configuration = AIChatInspectorDensityPresentation.configuration(isExpanded: false)

    XCTAssertEqual(configuration.sourcePresentation, .compactSummary)
    XCTAssertEqual(configuration.quickActionPresentation, .hidden)
    XCTAssertEqual(configuration.accessibilityState, "已折叠")
  }

  func testExpandedInspectorRestoresFullSourcesAndQuickActionsThroughMenus() {
    let configuration = AIChatInspectorDensityPresentation.configuration(isExpanded: true)

    XCTAssertEqual(configuration.sourcePresentation, .fullChips)
    XCTAssertEqual(configuration.quickActionPresentation, .menu)
    XCTAssertEqual(configuration.accessibilityState, "已展开")
  }

  func testCompactSummaryKeepsGeneralChatArticleBoundaryAndManualReferenceCount() {
    let summary = AIChatInspectorDensityPresentation.compactContextSummary(
      mode: .general,
      draftTitle: "不应出现的文章",
      explicitReferenceCount: 2,
      knowledgeTitle: "自动检索",
      agentTitle: "仅问答"
    )

    XCTAssertEqual(summary, "通用聊天：不读取当前文章 · 2 项手动引用 · 资料库：自动检索 · Agent：仅问答")
  }

  func testCollapsedAccessibilityValueExplainsHowToReachFullDetails() {
    let configuration = AIChatInspectorDensityPresentation.configuration(isExpanded: false)
    let value = AIChatInspectorDensityPresentation.disclosureAccessibilityValue(
      configuration: configuration,
      compactSummary: "当前文章：发布方案"
    )

    XCTAssertTrue(value.contains("已折叠"))
    XCTAssertTrue(value.contains("展开可查看完整来源、设置和快捷提示"))
  }
}
