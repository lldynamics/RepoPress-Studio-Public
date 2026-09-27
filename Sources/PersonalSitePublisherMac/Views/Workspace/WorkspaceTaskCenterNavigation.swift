import Foundation
import PublishingWorkbenchCore

/// A sheet can temporarily make its presenting window non-key. Record an
/// explicit navigation intent in that window before dismissing the sheet, so
/// key-window activation cannot restore the selection from before the action.
@MainActor
enum WorkspaceTaskCenterNavigation {
  static func locate(
    _ task: WorkbenchTaskItem,
    store: WorkbenchStore,
    windowSession: WorkspaceWindowSession
  ) -> String? {
    if let message = store.activityStatus.locateTask(task, windowID: windowSession.windowID) {
      return message
    }

    let section: WorkspaceSection
    let draftID: UUID?
    switch task.target {
    case .draft, .articleConversation:
      section = store.selectedSection
      draftID = store.selectedDraftID
    case .generalAIConversation:
      section = windowSession.selectedSection
      draftID = windowSession.selectedDraftID
    default:
      section = store.selectedSection
      draftID = windowSession.selectedDraftID
    }
    windowSession.selectContext(section: section, draftID: draftID) { _, _ in
      // The facade already applied the shared navigation. Only its window
      // intent needs updating here; other windows keep their own selections.
    }
    return nil
  }

  static func openSyncWorkspace(store: WorkbenchStore, windowSession: WorkspaceWindowSession) {
    store.operationLog.selectSyncWorkspace()
    windowSession.selectSection(.sync) { _ in }
  }
}
