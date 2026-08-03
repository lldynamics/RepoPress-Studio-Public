import SwiftUI

struct LocalSitePreviewCommandAction: Sendable {
  let open: @MainActor @Sendable () -> Void
}

private struct LocalSitePreviewCommandActionKey: FocusedValueKey {
  typealias Value = LocalSitePreviewCommandAction
}

private struct LocalSitePreviewCommandActionEnvironmentKey: EnvironmentKey {
  static let defaultValue: LocalSitePreviewCommandAction? = nil
}

extension FocusedValues {
  var localSitePreviewCommandAction: LocalSitePreviewCommandAction? {
    get { self[LocalSitePreviewCommandActionKey.self] }
    set { self[LocalSitePreviewCommandActionKey.self] = newValue }
  }
}

extension EnvironmentValues {
  var localSitePreviewCommandAction: LocalSitePreviewCommandAction? {
    get { self[LocalSitePreviewCommandActionEnvironmentKey.self] }
    set { self[LocalSitePreviewCommandActionEnvironmentKey.self] = newValue }
  }
}
