import SwiftUI

/// Opens the shared native Settings scene from the active workspace context.
/// The optional destination preserves deep links without replacing main-window content.
struct SettingsWorkspaceCommandAction: Sendable {
  let open: @MainActor @Sendable (SettingsDestination?) -> Void
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
