import XCTest

@testable import PublishingMarkdownCore

final class MarkdownInlineAttachmentPlanServiceTests: XCTestCase {
  func testPlansStandaloneImageAndBlockFormulaInUTF16Coordinates() throws {
    let markdown = "🙂\n![封面](<images/cover one.png>)\n$$x^2 + y^2$$"
    let plan = MarkdownInlineAttachmentPlanService.plan(in: markdown)

    XCTAssertEqual(plan.items.count, 2)
    guard case .image(let reference, let altText) = plan.items[0].kind else {
      return XCTFail("Expected image")
    }
    XCTAssertEqual(reference, "images/cover one.png")
    XCTAssertEqual(altText, "封面")
    XCTAssertEqual(
      (markdown as NSString).substring(with: plan.items[0].range), "![封面](<images/cover one.png>)")
    guard case .formula(let source, let displayMode) = plan.items[1].kind else {
      return XCTFail("Expected formula")
    }
    XCTAssertEqual(source, "x^2 + y^2")
    XCTAssertEqual(displayMode, .display)
  }

  func testExcludesCodeAndNonStandaloneFormula() {
    let markdown = "```\n![x](image.png)\n$$hidden$$\n```\nText $$inline$$ text"
    XCTAssertTrue(MarkdownInlineAttachmentPlanService.plan(in: markdown).items.isEmpty)
  }

  func testRejectsImageEmbeddedInProse() {
    let markdown = "before ![x](image.png) after"
    XCTAssertTrue(MarkdownInlineAttachmentPlanService.plan(in: markdown).items.isEmpty)
  }

  func testPlansMultilineDisplayFormula() throws {
    let markdown = "\\[\n\\frac{a}{b}\n\\]"
    let item = try XCTUnwrap(MarkdownInlineAttachmentPlanService.plan(in: markdown).items.first)
    guard case .formula(let source, let displayMode) = item.kind else {
      return XCTFail("Expected formula")
    }
    XCTAssertEqual(source, "\\frac{a}{b}")
    XCTAssertEqual(displayMode, .display)
  }

  func testPlansInlineFormulaWithoutTreatingCurrencyOrDisplayDelimitersAsInline() throws {
    let markdown = "质量与能量满足 $E = mc^2$，价格为 $5。\n\n$$x^2$$"
    let plan = MarkdownInlineAttachmentPlanService.plan(in: markdown)

    guard plan.items.count == 2 else {
      return XCTFail("Expected one inline formula and one display formula")
    }
    guard case .formula(let inlineSource, let inlineMode) = plan.items[0].kind else {
      return XCTFail("Expected inline formula")
    }
    XCTAssertEqual(inlineSource, "E = mc^2")
    XCTAssertEqual(inlineMode, .inline)
    XCTAssertEqual((markdown as NSString).substring(with: plan.items[0].range), "$E = mc^2$")

    guard case .formula(let displaySource, let displayMode) = plan.items[1].kind else {
      return XCTFail("Expected display formula")
    }
    XCTAssertEqual(displaySource, "x^2")
    XCTAssertEqual(displayMode, .display)
  }

  func testInlineFormulaExcludesEscapedDelimitersCodeAndWhitespaceBoundaries() {
    let markdown = #"\$escaped$ `$code$` $ spaced$ $trailing $ and $valid_1$"#
    let plan = MarkdownInlineAttachmentPlanService.plan(in: markdown)

    XCTAssertEqual(plan.items.count, 1)
    guard case .formula(let source, let displayMode) = plan.items[0].kind else {
      return XCTFail("Expected inline formula")
    }
    XCTAssertEqual(source, "valid_1")
    XCTAssertEqual(displayMode, .inline)
  }

  func testIncrementalUpdateShiftsAttachmentsAfterOrdinaryTextInsertion() throws {
    let previous = "开头\n\n公式 $E = mc^2$。\n\n$$x^2$$"
    let previousPlan = MarkdownInlineAttachmentPlanService.plan(in: previous)
    let insertionLocation = (previous as NSString).range(of: "开头").location + 1
    let current = (previous as NSString).replacingCharacters(
      in: NSRange(location: insertionLocation, length: 0),
      with: "正文"
    )

    let updatedPlan = try XCTUnwrap(
      MarkdownInlineAttachmentPlanService.incrementallyUpdatedPlan(
        previousPlan,
        previousMarkdown: previous,
        currentMarkdown: current,
        replacedRange: NSRange(location: insertionLocation, length: 0)
      )
    )
    XCTAssertEqual(updatedPlan, MarkdownInlineAttachmentPlanService.plan(in: current))
  }

  func testIncrementalUpdateFallsBackForStructuralAndAttachmentLineEdits() {
    let previous = "正文\n\n公式 $E = mc^2$。"
    let previousPlan = MarkdownInlineAttachmentPlanService.plan(in: previous)
    let bodyLocation = (previous as NSString).range(of: "正文").location + 1
    let formulaLineLocation = (previous as NSString).range(of: "公式").location + 1

    XCTAssertNil(
      MarkdownInlineAttachmentPlanService.incrementallyUpdatedPlan(
        previousPlan,
        previousMarkdown: previous,
        currentMarkdown: (previous as NSString).replacingCharacters(
          in: NSRange(location: bodyLocation, length: 0), with: "$"
        ),
        replacedRange: NSRange(location: bodyLocation, length: 0)
      )
    )
    XCTAssertNil(
      MarkdownInlineAttachmentPlanService.incrementallyUpdatedPlan(
        previousPlan,
        previousMarkdown: previous,
        currentMarkdown: (previous as NSString).replacingCharacters(
          in: NSRange(location: formulaLineLocation, length: 0), with: "新"
        ),
        replacedRange: NSRange(location: formulaLineLocation, length: 0)
      )
    )
  }
}
