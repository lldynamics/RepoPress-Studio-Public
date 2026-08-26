import Combine
import Foundation
import PublishingWorkbenchCore

struct KnowledgeContextQueryMetadata: Equatable, Sendable {
  let draftID: UUID
  let title: String
  let summary: String
  let tags: [String]

  init(draft: ArticleDraft) {
    draftID = draft.id
    title = draft.title
    summary = draft.summary
    tags = draft.tags
  }
}

/// Keeps high-frequency editor buffer notifications out of the SwiftUI view
/// graph. The current document is sampled only after the editor has been idle,
/// then the bounded knowledge query is built away from the main actor.
@MainActor
final class KnowledgeContextQueryRefreshCoordinator: ObservableObject {
  @Published private(set) var query = ""

  private let editorState: WorkbenchMarkdownEditorLiveContextFeatureFacade
  private let debounceDuration: Duration
  private var metadata: KnowledgeContextQueryMetadata
  private var editorStateCancellable: AnyCancellable?
  private var refreshTask: Task<Void, Never>?
  private var refreshGeneration: UInt64 = 0

  init(
    draft: ArticleDraft,
    store: WorkbenchStore,
    debounceDuration: Duration = .milliseconds(420)
  ) {
    metadata = KnowledgeContextQueryMetadata(draft: draft)
    self.debounceDuration = debounceDuration
    editorState = WorkbenchMarkdownEditorLiveContextFeatureFacade(
      store: store,
      draftID: draft.id
    )
    editorStateCancellable = editorState.objectWillChange.sink { [weak self] _ in
      self?.scheduleRefresh()
    }
    scheduleRefresh()
  }

  deinit {
    refreshTask?.cancel()
  }

  func updateMetadata(_ updatedMetadata: KnowledgeContextQueryMetadata) {
    guard metadata != updatedMetadata else { return }
    let didSwitchDraft = metadata.draftID != updatedMetadata.draftID
    metadata = updatedMetadata
    if didSwitchDraft {
      editorState.trackDraft(updatedMetadata.draftID)
      query = ""
    }
    scheduleRefresh()
  }

  private func scheduleRefresh() {
    refreshTask?.cancel()
    refreshGeneration &+= 1
    let generation = refreshGeneration
    let delay = debounceDuration
    refreshTask = Task { @MainActor [weak self] in
      do {
        try await Task.sleep(for: delay)
      } catch {
        return
      }
      guard let self,
        !Task.isCancelled,
        self.refreshGeneration == generation
      else {
        return
      }

      let metadata = self.metadata
      let input = KnowledgeContextQueryInput(
        title: metadata.title,
        summary: metadata.summary,
        tags: metadata.tags,
        bodyMarkdown: self.editorState.bodyMarkdown
      )
      let selectedRange = self.editorState.validatedSelectionRange
      let refreshedQuery = await Task.detached(priority: .utility) {
        KnowledgeContextQueryService.query(
          input: input,
          selectedRange: selectedRange
        )
      }.value

      guard !Task.isCancelled,
        self.refreshGeneration == generation,
        self.metadata == metadata
      else {
        return
      }
      if self.query != refreshedQuery {
        self.query = refreshedQuery
      }
    }
  }
}
