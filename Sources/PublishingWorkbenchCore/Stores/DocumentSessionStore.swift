import Combine
import Foundation

/// Process-local document editing state.
///
/// This keeps high-frequency body-buffer and caret updates out of the broad
/// publishing observation graph while retaining per-document conflict tokens.
@MainActor
public final class DocumentSessionStore {
  public internal(set) var markdownEditorSessionStates: [UUID: MarkdownEditorSessionState]
  public internal(set) var draftBodyEditorBuffers: [UUID: DraftBodyEditorBuffer] = [:]
  let draftBodyEditorBufferWillChange = PassthroughSubject<UUID, Never>()
  let draftBodyEditorBufferDidChange = PassthroughSubject<UUID, Never>()
  public internal(set) var activeEditorSelection: ActiveEditorSelection?
  let activeEditorSelectionDidChange = PassthroughSubject<UUID, Never>()

  init(
    markdownEditorSessionStates: [UUID: MarkdownEditorSessionState],
    activeEditorSelection: ActiveEditorSelection?
  ) {
    self.markdownEditorSessionStates = markdownEditorSessionStates
    self.activeEditorSelection = activeEditorSelection
  }

  func setDraftBodyEditorBuffer(
    _ buffer: DraftBodyEditorBuffer,
    for draftID: UUID,
    notifyObservers: Bool = true
  ) {
    guard draftBodyEditorBuffers[draftID] != buffer else { return }
    if notifyObservers {
      draftBodyEditorBufferWillChange.send(draftID)
    }
    draftBodyEditorBuffers[draftID] = buffer
    draftBodyEditorBufferDidChange.send(draftID)
  }

  func removeDraftBodyEditorBuffer(for draftID: UUID) {
    guard draftBodyEditorBuffers[draftID] != nil else { return }
    draftBodyEditorBufferWillChange.send(draftID)
    draftBodyEditorBuffers.removeValue(forKey: draftID)
    draftBodyEditorBufferDidChange.send(draftID)
  }
}
