import SwiftUI

struct DraftFullTextSearchAction {
  private let openAction: () -> Void
  private let openRequestAction: ((DraftFullTextSearchRequest) -> Void)?

  init(
    open: @escaping () -> Void,
    openRequest: ((DraftFullTextSearchRequest) -> Void)? = nil
  ) {
    openAction = open
    openRequestAction = openRequest
  }

  /// Retains the existing keyboard-command entry point.
  func open() {
    openAction()
  }

  /// Lets contextual controls preserve their visible query and corpus when
  /// opening the article scope of the shared command palette.
  func open(_ request: DraftFullTextSearchRequest) {
    if let openRequestAction {
      openRequestAction(request)
    } else {
      openAction()
    }
  }
}
