import Foundation

extension WorkbenchStore {
  public var aiWritingStylePreview: AIWritingStyleProfilePreview? {
    aiStore.aiWritingStylePreview
  }

  public var isAIWritingStyleExtractionRunning: Bool {
    aiStore.isAIWritingStyleExtractionRunning
  }

  @discardableResult
  public func generateAIWritingStyleProfile(
    exemplarArticleIDs: [UUID]
  ) async -> AIWritingStyleProfilePreview? {
    await aiStore.generateAIWritingStyleProfile(exemplarArticleIDs: exemplarArticleIDs)
  }

  @discardableResult
  public func applyAIWritingStyleProfile(_ preview: AIWritingStyleProfilePreview) -> Bool {
    aiStore.applyAIWritingStyleProfile(preview)
  }

  public func discardAIWritingStyleProfilePreview() {
    aiStore.discardAIWritingStyleProfilePreview()
  }
}
