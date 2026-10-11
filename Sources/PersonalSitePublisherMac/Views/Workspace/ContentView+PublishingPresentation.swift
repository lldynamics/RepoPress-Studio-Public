import PublishingWorkbenchCore
import SwiftUI

extension ContentView {
  func openPublishDrawer(
    message: String?,
    preferredScope: PublishScope? = nil,
    completedRecordID: UUID? = nil,
    preservingPublishFeedback: Bool = false
  ) {
    guard activateCurrentWindowSharedContext() else { return }
    clearArticlePublishRepair()
    windowSession.receiveSharedDraft(store.selectedDraftID)
    publishDrawerInitialScope = preferredScope ?? PublishScope.defaultScope
    directPublishCompletedRecordID = completedRecordID
    let showsInspector = prepareInspectorForUserRequest()
    deferredPublishIssue.cancel()
    isFocusMode = false
    windowSession.inspectorTab = .publish
    publishRequestGeneration &+= 1
    withAnimation(
      WorkbenchMotion.animation(
        for: .drawerPresentation,
        reduceMotion: accessibilityReduceMotion
      )
    ) {
      if showsInspector {
        modalPresentation.dismiss(.compactPublishInspector)
        store.setInspectorPresented(true)
      } else {
        modalPresentation.present(.compactPublishInspector)
      }
    }
    if !preservingPublishFeedback {
      store.setPublishActionMessage(
        message ?? String(localized: "发布流程已打开，请选择保存到本地或发布上线。"),
        status: .information
      )
    }
  }

  var compactPublishSheetContent: some View {
    VStack(spacing: 0) {
      HStack {
        Text("发布检查").font(.headline)
          .accessibilityIdentifier("workspace-compact-publish-sheet")
        Spacer()
        Button("关闭") { modalPresentation.dismiss(.compactPublishInspector) }
          .disabled(store.isRemoteRepositoryPublishing)
          .accessibilityIdentifier("compact-publish-close")
      }
      .padding(WorkbenchSpacing.control)
      Divider()
      PublishDrawerView(
        publishingFacade: store.publishing, store: store,
        draftID: windowSession.selectedDraftID,
        isPresented: modalIsPresentedBinding(.compactPublishInspector),
        initialScope: publishDrawerInitialScope,
        requestGeneration: publishRequestGeneration,
        initialCompletedReleaseRecordID: directPublishCompletedRecordID,
        onNavigateIssue: { draftID, target, scope in
          deferredPublishIssue.enqueue(
            profileID: store.activeProfileID, draftID: draftID, target: target, scope: scope)
          modalPresentation.dismiss(.compactPublishInspector)
        }
      )
    }
    .frame(width: 420, height: 620)
    .interactiveDismissDisabled(store.isRemoteRepositoryPublishing)
  }

  /// Runs for every site transition, including A -> B -> A before a render,
  /// so a deferred repair request from the old site can never be replayed.
  func resetProfileScopedWindowState() {
    windowSession.selectedContentHealthIssue = nil
    deferredPublishIssue.cancel()
  }

  func performDeferredPublishIssueIfReady() {
    guard modalPresentation.presented == nil,
      let request = deferredPublishIssue.consume(
        isKeyWindow: windowSession.isKeyWindow, currentProfileID: store.activeProfileID)
    else { return }
    navigateToPublishIssue(
      draftID: request.draftID, target: request.target, publishScope: request.scope)
  }
}
