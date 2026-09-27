import SwiftUI

/// Appearance has one complete home in the native Settings window.
struct MarkdownEditorComfortControl: View {
  var showsTitle = false
  @Environment(\.openSettings) private var openSettings
  @Environment(\.settingsWorkspaceCommandAction) private var settingsWorkspaceCommandAction

  var body: some View {
    Button {
      SettingsNavigation.present(
        destination: .tab(.editor),
        workspaceAction: settingsWorkspaceCommandAction
      ) {
        openSettings()
      }
    } label: {
      if showsTitle {
        Label("编辑器设置…", systemImage: "textformat.size")
          .labelStyle(.titleAndIcon)
          .font(.workbenchButtonLabel)
          .fixedSize(horizontal: true, vertical: false)
          .padding(.horizontal, 6)
          .frame(minHeight: 28)
      } else {
        Image(systemName: "textformat.size")
          .frame(width: 28, height: 28)
      }
    }
    .foregroundStyle(.secondary)
    .help("打开编辑器设置，调整字体、行距、正文宽度与编辑辅助。")
    .accessibilityLabel("编辑器设置")
    .accessibilityIdentifier("markdown-editor-settings")
  }
}
