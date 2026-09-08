import XCTest

@testable import PublishingWorkbenchCore

@MainActor
final class WritingDraftTemplateTests: XCTestCase {
  func testTemplateCreationCreatesOneOwnedDraftWithExpandedBody() throws {
    let store = makeStore()
    let initialCount = store.drafts.count
    let template = try XCTUnwrap(
      MarkdownSnippetLibraryService.builtIns.first { $0.id == "template-guide" }
    )

    let id = try XCTUnwrap(store.createDraft(from: template, asGeneralDraft: false, title: "测试教程"))
    XCTAssertEqual(store.drafts.count, initialCount + 1)
    let draft = try XCTUnwrap(store.drafts.first { $0.id == id })
    XCTAssertTrue(draft.bodyMarkdown.contains("## 操作步骤"))
    XCTAssertTrue(draft.bodyMarkdown.contains("# 测试教程"))
    XCTAssertFalse(draft.bodyMarkdown.contains("{{title}}"))
    XCTAssertTrue(draft.isGeneralDraft == false)
    XCTAssertEqual(store.selectedDraftID, id)
    XCTAssertEqual(store.draftListContentScope, .currentSite)
  }

  func testInvalidTemplateDoesNotCreateAnEmptyDraft() {
    let store = makeStore()
    let initialCount = store.drafts.count
    let invalid = MarkdownSnippet(
      id: "invalid", title: "空", detail: "", systemImage: "doc",
      kind: .snippet, markdown: ""
    )
    XCTAssertNil(store.createDraft(from: invalid, asGeneralDraft: true))
    XCTAssertEqual(store.drafts.count, initialCount)
  }

  func testGeneralTemplateKeepsGeneralOwnershipAndRejectsOtherSiteTemplate() throws {
    let store = makeStore()
    var template = try XCTUnwrap(MarkdownSnippetLibraryService.builtIns.first { $0.kind == .articleTemplate })
    let id = try XCTUnwrap(store.createDraft(from: template, asGeneralDraft: true))
    let draft = try XCTUnwrap(store.draft(for: id))
    XCTAssertTrue(draft.isGeneralDraft)
    XCTAssertEqual(store.draftListContentScope, .general)
    XCTAssertNil(draft.repositoryPath)
    let count = store.drafts.count
    template.siteProfileID = UUID()
    XCTAssertNil(store.createDraft(from: template, asGeneralDraft: false))
    XCTAssertEqual(store.drafts.count, count)
  }

  private func makeStore() -> WorkbenchStore {
    WorkbenchStore(
      persistence: WorkbenchPersistence(
        fileURL: FileManager.default.temporaryDirectory
          .appendingPathComponent("template-draft-\(UUID().uuidString).json")
      ),
      safeMode: true
    )
  }
}
