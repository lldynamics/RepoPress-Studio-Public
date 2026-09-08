import XCTest

@testable import PersonalSitePublisherMac
@testable import PublishingWorkbenchCore

final class ContentHealthAIFixFieldPolicyTests: XCTestCase {
  func testCommaInsideOneTagDoesNotMatchTwoTagBaseline() {
    var draft = ArticleDraft(siteProfileID: UUID(), title: "Tags", tags: ["Swift", "macOS"])
    let baseline = ContentHealthAIFixFieldPolicy.baseline(for: draft)
    draft.tags = ["Swift, macOS"]
    let field = FrontMatterFixFieldItem(
      id: "tags", fieldKey: "tags", title: "Tags", proposedValue: "New", isSelected: true)
    let result = ContentHealthAIFixFieldPolicy.apply([field], to: &draft, baseline: baseline)
    XCTAssertEqual(result.conflictCount, 1)
    XCTAssertEqual(draft.tags, ["Swift, macOS"])
  }

  func testOnlyImplementedFieldsAreSelectableAndApplied() {
    var draft = ArticleDraft(siteProfileID: UUID(), title: "原始标题", slug: "before")
    let fields = [
      FrontMatterFixFieldItem(
        id: "title", fieldKey: "title", title: "标题", proposedValue: "新标题", isSelected: true),
      FrontMatterFixFieldItem(
        id: "date", fieldKey: "date", title: "日期", proposedValue: "2026-08-06", isSelected: true),
      FrontMatterFixFieldItem(
        id: "categories", fieldKey: "categories", title: "分类", proposedValue: "新闻", isSelected: true
      ),
    ]

    XCTAssertTrue(fields[0].isSupported)
    XCTAssertFalse(fields[1].isSupported)
    XCTAssertFalse(fields[2].isSupported)

    let result = ContentHealthAIFixFieldPolicy.apply(fields, to: &draft)

    XCTAssertEqual(draft.title, "新标题")
    XCTAssertEqual(result.appliedKeys, ["title"])
    XCTAssertEqual(result.skippedKeys, ["date", "categories"])
    XCTAssertTrue(result.conflicts.isEmpty)
    XCTAssertEqual(
      ContentHealthAIFixApplyFeedback.applied(result).message,
      "已应用 1 个字段，跳过 2 个当前不支持的字段。"
    )
  }

  func testUnsupportedFieldsCannotInflateSelectedCount() {
    let unsupported = FrontMatterFixFieldItem(
      id: "draft", fieldKey: "draft", title: "草稿状态", proposedValue: "false", isSelected: false)

    XCTAssertFalse(unsupported.isSupported)
    XCTAssertFalse(ContentHealthAIFixFieldPolicy.supports("aliases"))
    XCTAssertTrue(ContentHealthAIFixFieldPolicy.supports(" description "))
  }

  func testChangedFieldIsNotOverwrittenWhileUnchangedFieldStillApplies() {
    var draft = ArticleDraft(
      siteProfileID: UUID(), title: "另一窗口标题", slug: "before", summary: "原摘要")
    let fields = [
      FrontMatterFixFieldItem(
        id: "title", fieldKey: "title", title: "标题", proposedValue: "AI 标题", isSelected: true),
      FrontMatterFixFieldItem(
        id: "summary", fieldKey: "summary", title: "摘要", proposedValue: "AI 摘要", isSelected: true),
    ]

    let result = ContentHealthAIFixFieldPolicy.apply(
      fields,
      to: &draft,
      baseline: ["title": ["生成时标题"], "summary": ["原摘要"]]
    )

    XCTAssertEqual(draft.title, "另一窗口标题")
    XCTAssertEqual(draft.summary, "AI 摘要")
    XCTAssertEqual(result.appliedKeys, ["summary"])
    XCTAssertEqual(
      result.conflicts,
      [
        ContentHealthAIFixFieldConflict(fieldKey: "title", currentValue: "另一窗口标题")
      ])
  }
}
