import XCTest
@testable import PersonalSitePublisherMac
@testable import PublishingWorkbenchCore

final class WorkspaceTaskInspectorIssuePresentationTests: XCTestCase {
  func testEditorQueryUsesRelatedValueForUnregisteredBodyImageRegardlessOfLocalizedCopy() {
    let issue = PreflightIssue(
      severity: .warning,
      title: "Arbitrary localized title",
      message: "Arbitrary localized message",
      field: "body",
      category: .unregisteredBodyImage,
      relatedValue: "/images/diagram.png"
    )

    XCTAssertEqual(issue.editorQuery, "/images/diagram.png")
  }

  func testEditorQueryRejectsRelatedValueFromOtherStructuredIssues() {
    let otherCategory = PreflightIssue(
      severity: .warning,
      title: "Arbitrary title",
      message: "Arbitrary message",
      field: "body",
      category: .publicRisk,
      relatedValue: "/images/diagram.png"
    )
    let otherField = PreflightIssue(
      severity: .warning,
      title: "Arbitrary title",
      message: "Arbitrary message",
      field: "attachments",
      category: .unregisteredBodyImage,
      relatedValue: "/images/diagram.png"
    )

    XCTAssertNil(otherCategory.editorQuery)
    XCTAssertNil(otherField.editorQuery)
  }

  func testIssueFocusTargetUsesStructuredFieldInsteadOfLocalizedCopy() {
    XCTAssertEqual(issue(field: "body").contentHealthFocusTargetTitle, "正文")
    XCTAssertEqual(issue(field: "summary").contentHealthFocusTargetTitle, "摘要")
    XCTAssertEqual(issue(field: "attachments").contentHealthFocusTargetTitle, "图片")
    XCTAssertEqual(issue(field: "title").contentHealthFocusTargetTitle, "元数据")
  }

  func testWritingContextPanelsAndToolDensitiesAreExplicitlyEnumerated() {
    XCTAssertEqual(
      Set(MarkdownWritingContextPanel.allCases),
      Set([.selectionTools, .aiReview, .imageInfo, .outline])
    )
    XCTAssertEqual(
      MarkdownWritingToolDensity.allCases.map(\.title),
      ["基础写作", "专业 Markdown"]
    )
  }

  func testWritingInspectorUsesDedicatedKnowledgePage() {
    XCTAssertEqual(ArticleInspectorTab.defaultTab(for: .writing), .knowledge)
    XCTAssertEqual(
      ArticleInspectorTab.availableTabs(for: .writing),
      [.knowledge, .metadata, .seo]
    )
    XCTAssertEqual(ArticleInspectorTab.knowledge.title, "上下文知识建议")
    XCTAssertEqual(ArticleInspectorTab.knowledge.pickerTitle, "知识建议")
    XCTAssertFalse(ArticleInspectorTab.availableTabs(for: .contentHealth).contains(.knowledge))
  }

  private func issue(field: String) -> PreflightIssue {
    PreflightIssue(
      severity: .warning,
      title: "标题",
      message: "消息",
      field: field
    )
  }
}
