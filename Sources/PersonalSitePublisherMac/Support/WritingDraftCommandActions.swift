import SwiftUI

struct WritingDraftCommandActions {
  var createDraft: () -> Void
  /// Creates a reusable draft using the same store operation as the writing
  /// list's empty state and toolbar.
  var createGeneralDraft: (() -> Void)? = nil
  /// Presents the writing column's existing template picker sheet.
  var presentTemplatePicker: (() -> Void)? = nil
  var focusSearch: () -> Void
  var openVersionHistory: () -> Void
  var selectPreviousDraft: () -> Void
  var selectNextDraft: () -> Void
}
