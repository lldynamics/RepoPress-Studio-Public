import XCTest

@testable import PublishingWorkbenchCore

@MainActor
func installAIMetadataSuggestionForApplicationTest(
  _ suggestion: AIPublishingMetadataSuggestion, draft: ArticleDraft, store: WorkbenchStore,
  file: StaticString = #filePath, line: UInt = #line
) {
  let generation = store.aiStore.beginAIMetadataSuggestionOperation(for: draft.id)
  XCTAssertTrue(
    store.aiStore.installAIMetadataSuggestion(
      suggestion, for: draft.id, generation: generation), file: file, line: line)
  store.aiStore.finishAIMetadataSuggestionOperation(for: draft.id, generation: generation)
}
