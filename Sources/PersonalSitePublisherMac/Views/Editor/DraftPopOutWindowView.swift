import PublishingWorkbenchCore
import SwiftUI

/// An editor-only scene backed by the same revisioned draft buffers as the
/// workspace. Navigation and command routing remain local to this window.
struct DraftPopOutWindowView: View {
  let store: WorkbenchStore
  let draftID: UUID
  @ObservedObject private var draftList: DraftListStore
  @ObservedObject private var rootPresentation: WorkbenchRootPresentationFeatureFacade
  @Environment(\.controlActiveState) private var controlActiveState
  @StateObject private var windowSession: WorkspaceWindowSession
  @StateObject private var sceneCommandRouter = WorkspaceSceneCommandRouter()

  init(store: WorkbenchStore, draftID: UUID) {
    self.store = store
    self.draftID = draftID
    _draftList = ObservedObject(wrappedValue: store.draftList)
    _rootPresentation = ObservedObject(wrappedValue: store.rootPresentation)
    _windowSession = StateObject(
      wrappedValue: WorkspaceWindowSession(selectedSection: .writing, selectedDraftID: draftID)
    )
  }

  var body: some View {
    Group {
      if let draft = store.draft(for: draftID) {
        MacMarkdownComposerView(
          draft: Binding(
            get: { store.draft(for: draftID) ?? draft },
            set: { store.updateDraftFromEditor($0) }
          ),
          store: store
        )
        .id(draftID)
        .navigationTitle(
          rootPresentation.isQuickHideActive
            ? String(localized: "独立草稿")
            : store.privateContentDisplay(for: draft).title
        )
      } else {
        ContentUnavailableView(
          "草稿已不可用",
          systemImage: "doc.questionmark",
          description: Text("这篇草稿已从工作区移除。")
        )
        .navigationTitle("独立草稿")
      }
    }
    .frame(minWidth: 620, minHeight: 440)
    .environment(\.workspaceWindowID, windowSession.windowID)
    .environment(\.workspaceWindowSession, windowSession)
    .environment(\.workspaceWindowIsKey, windowSession.isKeyWindow)
    .environmentObject(sceneCommandRouter)
    .focusedSceneObject(sceneCommandRouter)
    .disabled(rootPresentation.isQuickHideActive)
    .overlay {
      if rootPresentation.isQuickHideActive {
        QuickHideOverlay(store: store)
      }
    }
    .onAppear(perform: synchronizeWindowActivity)
    .onChange(of: controlActiveState) { _, _ in
      synchronizeWindowActivity()
    }
    .onDisappear {
      windowSession.setKeyWindow(false) { _, _ in }
      sceneCommandRouter.clearAll()
    }
  }

  private func synchronizeWindowActivity() {
    windowSession.setKeyWindow(controlActiveState == .key) { section, selectedDraftID in
      if store.selectedSection != section {
        store.selectSection(section)
      }
      _ = store.activateDraftSelectionContext(selectedDraftID)
    }
  }
}
