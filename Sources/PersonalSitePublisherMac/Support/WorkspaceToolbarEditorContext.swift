import Combine
import Foundation

/// The small, editor-owned projection consumed by the workspace toolbar.
///
/// It deliberately contains no document text or general workspace state, so a
/// toolbar observer can update for live writing statistics without subscribing
/// to the root workspace store.
struct WorkspaceToolbarEditorContext: Equatable, Sendable {
  let ownerID: UUID
  let draftID: UUID
  /// Nil represents an editor that has not produced its first statistics
  /// snapshot yet. It deliberately is not rendered as “0 字 · 1 分钟”.
  let writingUnitCount: Int?
  let readingMinutes: Int?
}

@MainActor
final class WorkspaceToolbarEditorContextStore: ObservableObject {
  @Published private(set) var context: WorkspaceToolbarEditorContext?

  /// Makes an editor the current toolbar source. Switching either identity
  /// starts from an empty projection so a new draft can never show the prior
  /// draft's counters while its editor finishes its initial statistics pass.
  func activate(ownerID: UUID, draftID: UUID) {
    guard context?.ownerID != ownerID || context?.draftID != draftID else { return }
    context = WorkspaceToolbarEditorContext(
      ownerID: ownerID,
      draftID: draftID,
      writingUnitCount: nil,
      readingMinutes: nil
    )
  }

  /// Accepts statistics only from the editor that is currently routed to this
  /// scene. Late callbacks from another owner or a previous draft are ignored.
  func update(
    ownerID: UUID,
    draftID: UUID,
    writingUnitCount: Int,
    readingMinutes: Int
  ) {
    guard let context, context.ownerID == ownerID, context.draftID == draftID else {
      return
    }

    let updatedContext = WorkspaceToolbarEditorContext(
      ownerID: ownerID,
      draftID: draftID,
      writingUnitCount: writingUnitCount,
      readingMinutes: readingMinutes
    )
    guard context != updatedContext else { return }
    self.context = updatedContext
  }

  /// Clears only the active owner's projection; a disappearing stale view must
  /// not erase the editor that most recently became active.
  func clear(ownerID: UUID) {
    guard context?.ownerID == ownerID else { return }
    context = nil
  }

  func clear() {
    guard context != nil else { return }
    context = nil
  }
}
