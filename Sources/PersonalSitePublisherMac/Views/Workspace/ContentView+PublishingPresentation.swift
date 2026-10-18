import PublishingWorkbenchCore
import SwiftUI

extension ContentView {
  /// Shows the 发布检查 panel: in the inspector when the window has room for
  /// it, otherwise in a sheet. Publishing still goes through its own sheet.
  func openPublishChecks(message: String? = nil) {
    guard activateCurrentWindowSharedContext() else { return }
    clearArticlePublishRepair()
    windowSession.receiveSharedDraft(store.selectedDraftID)
    let showsInspector = prepareInspectorForUserRequest()
    deferredPublishIssue.cancel()
    isFocusMode = false
    windowSession.inspectorTab = .publish
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
    if let message {
      store.setPublishActionMessage(message, status: .information)
    }
  }

  var compactPublishSheetContent: some View {
    VStack(spacing: 0) {
      HStack {
        Text("发布检查").font(.workbenchHeadline)
          .accessibilityIdentifier("workspace-compact-publish-sheet")
        Spacer()
        Button("关闭") { modalPresentation.dismiss(.compactPublishInspector) }
          .accessibilityIdentifier("compact-publish-close")
      }
      .padding(WorkbenchSpacing.control)
      Divider()
      PublishChecklistView(
        publishingFacade: store.publishing, store: store,
        draftID: windowSession.selectedDraftID,
        onNavigateIssue: { draftID, target in
          deferredPublishIssue.enqueue(
            profileID: store.activeProfileID, draftID: draftID, target: target)
          modalPresentation.dismiss(.compactPublishInspector)
        }
      )
    }
    .frame(width: 420, height: 620)
  }

  /// The one sheet of the publish flow. Its content follows the session:
  /// confirmation, blocking checks, push retry, then the outcome.
  @ViewBuilder
  var publishSheetContent: some View {
    if let review = publishSession.pendingReview {
      RepositoryWorktreePublishConfirmationView(
        confirmation: review.confirmation,
        subject: review.title,
        siteName: store.activeProfile.name,
        isUpdate: review.target.draftID.flatMap(store.draft(for:))?.articleState == .published,
        note: review.clearedDraftFlag
          ? String(localized: "这篇文章原是草稿，已为本次发布取消草稿标记；取消发布会恢复为草稿。") : nil,
        isPublishing: publishSession.isPublishing,
        cancelAction: { publishSession.discardReview(store: store) },
        confirmAction: { publishSession.confirm(review, store: store) }
      )
      .interactiveDismissDisabled(publishSession.isPublishing)
    } else if let confirmation = publishSession.pendingPushRetry {
      RepositoryWorktreePushRetryConfirmationView(
        confirmation: confirmation,
        isPublishing: publishSession.isPublishing,
        cancelAction: { publishSession.discardPushRetry() },
        confirmAction: { publishSession.confirmPushRetry(confirmation, store: store) },
        feedback: nil,
        reviewAgainAction: { publishSession.preparePushRetry(store: store) }
      )
      .interactiveDismissDisabled(publishSession.isPublishing)
    } else if let blockers = publishSession.pendingBlockers {
      PublishBlockersView(
        blockers: blockers,
        navigate: { target in
          publishSession.pendingBlockers = nil
          deferredPublishIssue.enqueue(
            profileID: store.activeProfileID, draftID: blockers.draftID, target: target)
        },
        dismissAction: { publishSession.pendingBlockers = nil }
      )
    } else if let outcome = publishSession.outcome {
      PublishOutcomeView(
        store: store,
        outcome: outcome,
        isBusy: publishSession.isBusy,
        retryPushAction: { publishSession.preparePushRetry(store: store) },
        openHistoryAction: {
          publishSession.outcome = nil
          openReleaseHistorySubpage()
        },
        dismissAction: { publishSession.outcome = nil }
      )
    }
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
    navigateToPublishIssue(draftID: request.draftID, target: request.target)
  }
}
