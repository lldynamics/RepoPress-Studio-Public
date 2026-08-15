import Combine
import Foundation

/// Publishes only the state that can change the root workbench presentation.
/// Draft body edits, publishing progress, and token-by-token AI responses stay
/// within their feature views instead of invalidating `ContentView`.
@MainActor
public final class WorkbenchContentPresentationFeatureFacade: ObservableObject {
  private unowned let store: WorkbenchStore
  private var cancellables = Set<AnyCancellable>()
  private var isChangeNotificationScheduled = false

  init(store: WorkbenchStore) {
    self.store = store
    observeValue(store.publishingStore.$editorDisplayMode)
    observeValue(store.aiWorkspaceStore.$isAIPublishingAssistantPresented)
  }

  public var editorDisplayMode: EditorDisplayMode {
    store.editorDisplayMode
  }

  public var isAssistantPresented: Bool {
    store.isAIPublishingAssistantPresented
  }

  public func hideAssistant() {
    store.hideAIPublishingAssistant()
  }

  public func closeAssistantPanel() {
    store.hideAIPublishingAssistant()
    store.setInspectorPresented(false)
  }

  public var selectedDraftID: UUID? {
    store.selectedDraftID
  }

  public var recycledDrafts: [RecycledDraft] {
    store.recycledDrafts
  }

  public var drafts: [ArticleDraft] {
    store.drafts
  }

  public func versions(for draftID: UUID) -> [DraftVersionSnapshot] {
    store.versions(for: draftID)
  }

  @discardableResult
  public func restoreDraftVersion(_ versionID: UUID) -> Bool {
    store.restoreDraftVersion(versionID)
  }

  @discardableResult
  public func restoreRecycledDraft(_ draftID: UUID) -> Bool {
    store.restoreRecycledDraft(draftID)
  }

  public func permanentlyDeleteRecycledDraft(_ id: UUID) -> Bool {
    store.permanentlyDeleteRecycledDraft(id)
  }

  private func observeValue<P: Publisher>(_ publisher: P)
  where P.Failure == Never, P.Output: Equatable {
    publisher
      .removeDuplicates()
      .dropFirst()
      .sink { [weak self] _ in self?.scheduleChangeNotification() }
      .store(in: &cancellables)
  }

  private func scheduleChangeNotification() {
    guard !isChangeNotificationScheduled else { return }
    isChangeNotificationScheduled = true

    // Deliver after the source @Published properties leave willSet so layout
    // decisions use committed values, including while AppKit is tracking an
    // accessibility or mouse event.
    RunLoop.main.perform(inModes: [
      .default,
      RunLoop.Mode("NSEventTrackingRunLoopMode"),
    ]) { [weak self] in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.isChangeNotificationScheduled = false
        self.objectWillChange.send()
      }
    }
  }
}
