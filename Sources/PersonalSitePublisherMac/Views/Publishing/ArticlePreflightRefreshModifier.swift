import PublishingCoreSupport
import PublishingWorkbenchCore
import SwiftUI

/// A window's automatic or explicitly opened checks share the Store's work.
/// The view owns only its debounced waiter; cancelling it does not stop a
/// calculation that another window is waiting for.
private struct ArticlePreflightRefreshModifier: ViewModifier {
  let store: WorkbenchStore
  let draftID: UUID?
  let isEnabled: Bool

  func body(content: Content) -> some View {
    content.task(id: isEnabled ? draftID.flatMap(store.draftPreflightRefreshIdentity(for:)) : nil) {
      guard isEnabled, let draftID,
        store.draft(for: draftID)?.isGeneralDraft == false
      else { return }
      do {
        try await Task.sleep(for: DebounceIntervals.preflightRefresh)
        try Task.checkCancellation()
      } catch {
        return
      }
      _ = await store.ensurePreflight(for: draftID)
    }
  }
}

extension View {
  func articlePreflightRefresh(store: WorkbenchStore, draftID: UUID?, isEnabled: Bool) -> some View
  {
    modifier(ArticlePreflightRefreshModifier(store: store, draftID: draftID, isEnabled: isEnabled))
  }
}
