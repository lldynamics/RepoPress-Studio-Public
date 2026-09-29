import SwiftUI

struct LocalSitePreviewCommandAction: Sendable {
  let open: @MainActor @Sendable () -> Void
}

private struct LocalSitePreviewCommandActionEnvironmentKey: EnvironmentKey {
  static let defaultValue: LocalSitePreviewCommandAction? = nil
}

extension EnvironmentValues {
  var localSitePreviewCommandAction: LocalSitePreviewCommandAction? {
    get { self[LocalSitePreviewCommandActionEnvironmentKey.self] }
    set { self[LocalSitePreviewCommandActionEnvironmentKey.self] = newValue }
  }
}
