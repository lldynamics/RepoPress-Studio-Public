import SwiftUI

/// Presents the complete Settings workspace inside the active main window.
///
/// The optional destination keeps existing deep links useful while the close
/// action restores the exact workbench context that was visible beforehand.
struct SettingsWorkspaceCommandAction: Sendable {
  let isPresented: Bool
  let open: @MainActor @Sendable (SettingsDestination?) -> Void
  let close: @MainActor @Sendable () -> Void
}

private struct SettingsWorkspaceCommandActionEnvironmentKey: EnvironmentKey {
  static let defaultValue: SettingsWorkspaceCommandAction? = nil
}

extension EnvironmentValues {
  var settingsWorkspaceCommandAction: SettingsWorkspaceCommandAction? {
    get { self[SettingsWorkspaceCommandActionEnvironmentKey.self] }
    set { self[SettingsWorkspaceCommandActionEnvironmentKey.self] = newValue }
  }
}
