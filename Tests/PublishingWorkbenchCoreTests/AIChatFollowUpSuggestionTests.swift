import Foundation
import XCTest

@testable import PublishingWorkbenchCore

final class AIChatFollowUpSuggestionTests: XCTestCase {
  func testExtractsExplicitFollowUpSuggestionsAndCleansDisplayContent() throws {
    let raw = """
      这里是给你的核心建议。

      <follow_up_suggestions>
      [
        {
          "title": "一键应用修改",
          "prompt": "请将上述修改应用到正文。",
          "kind": "toolAction",
          "icon": "doc.text.fill",
          "toolCommand": "applyDiff"
        },
        {
          "title": "补充案例",
          "prompt": "请在第二节补充一个具体案例。",
          "kind": "prompt",
          "icon": "sparkles"
        }
      ]
      </follow_up_suggestions>
      """

    let result = AIChatFollowUpSuggestionService.extractOrInferSuggestions(content: raw)
    XCTAssertEqual(result.displayContent, "这里是给你的核心建议。")
    XCTAssertEqual(result.suggestions.count, 2)
    XCTAssertEqual(result.suggestions[0].title, "一键应用修改")
    XCTAssertEqual(result.suggestions[0].kind, .toolAction)
    XCTAssertEqual(result.suggestions[0].toolCommand, .applyDiff)
    XCTAssertEqual(result.suggestions[1].title, "补充案例")
    XCTAssertEqual(result.suggestions[1].kind, .prompt)
  }

  func testInfersDefaultSuggestionsForCodeBlocks() {
    let content = """
      以下是 Swift 实现方案：
      ```swift
      func hello() { print("World") }
      ```
      """
    let result = AIChatFollowUpSuggestionService.extractOrInferSuggestions(content: content)
    XCTAssertEqual(result.displayContent, content)
    XCTAssertFalse(result.suggestions.isEmpty)
    XCTAssertTrue(result.suggestions.contains(where: { $0.title.contains("代码") }))
  }

  func testInfersDefaultSuggestionsForOutlines() {
    let content = "这是文章的整体大纲，分为三个主要章节。"
    let result = AIChatFollowUpSuggestionService.extractOrInferSuggestions(content: content)
    XCTAssertFalse(result.suggestions.isEmpty)
    XCTAssertTrue(result.suggestions.contains(where: { $0.title.contains("大纲") }))
  }

  func testAutomationRegistryIncludesAllNewDomainTools() {
    let commandIDs = Set(WorkbenchAutomationRegistry.descriptors.map(\.id))
    XCTAssertTrue(commandIDs.contains(.draftRead))
    XCTAssertTrue(commandIDs.contains(.searchDrafts))
    XCTAssertTrue(commandIDs.contains(.auditContent))
    XCTAssertTrue(commandIDs.contains(.applyDiff))
    XCTAssertTrue(commandIDs.contains(.generateFrontmatter))
    XCTAssertTrue(commandIDs.contains(.webFetch))
    XCTAssertTrue(commandIDs.contains(.webSearch))
    XCTAssertTrue(commandIDs.contains(.siteCheckLinks))
    XCTAssertTrue(commandIDs.contains(.siteOptimizeImages))
    XCTAssertTrue(commandIDs.contains(.siteDeployStatus))
  }

  func testDraftReadAndLinkCheckAreReadOnly() {
    XCTAssertEqual(WorkbenchAutomationRegistry.descriptor(for: .draftRead)?.risk, .readOnly)
    XCTAssertEqual(WorkbenchAutomationRegistry.descriptor(for: .siteCheckLinks)?.risk, .readOnly)
    XCTAssertEqual(WorkbenchAutomationRegistry.descriptor(for: .siteOptimizeImages)?.risk, .readOnly)
    XCTAssertEqual(WorkbenchAutomationRegistry.descriptor(for: .siteDeployStatus)?.risk, .readOnly)
    XCTAssertEqual(WorkbenchAutomationRegistry.descriptor(for: .webFetch)?.risk, .readOnly)
    XCTAssertEqual(WorkbenchAutomationRegistry.descriptor(for: .webSearch)?.risk, .readOnly)
  }

  func testApplyDiffRequiresExplicitContentChangeRisk() {
    XCTAssertEqual(WorkbenchAutomationRegistry.descriptor(for: .applyDiff)?.risk, .contentChange)
    XCTAssertEqual(WorkbenchAutomationRegistry.descriptor(for: .generateFrontmatter)?.risk, .contentChange)
  }

  func testApplyDiffMutationPreviewReplacesTargetTextAccurately() throws {
    let draft = ArticleDraft(
      siteProfileID: SiteProfile.defaultProfileID,
      title: "测试文章",
      bodyMarkdown: "Hello old world! This is a test draft."
    )
    let step = WorkbenchAutomationStep(
      command: .applyDiff,
      arguments: WorkbenchAutomationArguments(
        draftID: draft.id,
        expectedDraftUpdatedAt: draft.updatedAt,
        originalText: "old world",
        replacementText: "brave new world"
      )
    )

    let preview = try WorkbenchAutomationDraftMutationService.preview(step: step, draft: draft)
    XCTAssertEqual(preview.updatedDraft.bodyMarkdown, "Hello brave new world! This is a test draft.")
  }
}
