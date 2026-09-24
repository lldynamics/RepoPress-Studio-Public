import SwiftUI

/// The most common settings tasks, presented as direct links from the site overview.
///
/// Keep these destinations backed by `SettingsDestination` so the overview uses the
/// same routing and deep-link semantics as the sidebar and workspace commands.
enum SettingsTaskShortcut: CaseIterable, Hashable, Identifiable {
  case publishing
  case aiConnection
  case editor
  case backup

  var id: String {
    destination.id
  }

  var title: String {
    switch self {
    case .publishing:
      return String(localized: "发布配置")
    case .aiConnection:
      return String(localized: "AI 连接")
    case .editor:
      return String(localized: "编辑器偏好")
    case .backup:
      return String(localized: "备份与恢复")
    }
  }

  var detail: String {
    switch self {
    case .publishing:
      return String(localized: "调整内容路径和发布规则")
    case .aiConnection:
      return String(localized: "检查账户、凭据和连接状态")
    case .editor:
      return String(localized: "调整编辑器和输入体验")
    case .backup:
      return String(localized: "管理草稿、备份和迁移")
    }
  }

  var systemImage: String {
    switch self {
    case .publishing:
      return "arrow.up.doc"
    case .aiConnection:
      return "sparkles"
    case .editor:
      return "character.cursor.ibeam"
    case .backup:
      return "externaldrive"
    }
  }

  var destination: SettingsDestination {
    switch self {
    case .publishing:
      return .rules(.paths)
    case .aiConnection:
      return .ai(.connection)
    case .editor:
      return .tab(.editor)
    case .backup:
      return .data(.backup)
    }
  }

  var scopePresentation: SettingsScopePresentation {
    destination.tab.scopePresentation
  }
}

@MainActor
struct SettingsTaskShortcutsView: View {
  let selectDestination: (SettingsDestination) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: WorkbenchSpacing.control) {
      VStack(alignment: .leading, spacing: 3) {
        Text("常用任务")
          .font(.workbenchSectionTitle)
        Text("从这里直接打开最常用的设置")
          .font(.callout)
          .foregroundStyle(.secondary)
      }

      ViewThatFits(in: .horizontal) {
        LazyVGrid(
          columns: [
            GridItem(.flexible(minimum: 220), spacing: WorkbenchSpacing.control),
            GridItem(.flexible(minimum: 220), spacing: WorkbenchSpacing.control),
          ],
          alignment: .leading,
          spacing: WorkbenchSpacing.control
        ) {
          shortcutButtons
        }

        LazyVGrid(
          columns: [GridItem(.adaptive(minimum: 220), spacing: WorkbenchSpacing.control)],
          alignment: .leading,
          spacing: WorkbenchSpacing.control
        ) {
          shortcutButtons
        }
      }
    }
    .padding(WorkbenchSpacing.content)
    .background(
      Color(nsColor: .controlBackgroundColor),
      in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
    )
    .overlay {
      RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
        .strokeBorder(Color.primary.opacity(0.08))
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("settings-task-shortcuts")
  }

  @ViewBuilder
  private var shortcutButtons: some View {
    ForEach(SettingsTaskShortcut.allCases) { shortcut in
      Button {
        selectDestination(shortcut.destination)
      } label: {
        HStack(alignment: .center, spacing: WorkbenchSpacing.control) {
          Image(systemName: shortcut.systemImage)
            .font(.body.weight(.semibold))
            .foregroundStyle(WorkbenchTheme.primary)
            .frame(width: 22)
            .accessibilityHidden(true)

          VStack(alignment: .leading, spacing: 3) {
            Text(shortcut.title)
              .font(.body.weight(.medium))
              .foregroundStyle(.primary)
            Text(shortcut.detail)
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(2)
              .multilineTextAlignment(.leading)

            Label(
              shortcut.scopePresentation.badgeTitle,
              systemImage: shortcut.scopePresentation.systemImage
            )
            .font(.workbenchMetadata)
            .foregroundStyle(.secondary)
          }

          Spacer(minLength: 4)

          Image(systemName: "chevron.right")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
        .padding(.horizontal, WorkbenchSpacing.control)
        .padding(.vertical, 8)
        .background(
          Color.primary.opacity(0.035),
          in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
        )
      }
      .buttonStyle(.plain)
      .accessibilityLabel(shortcut.title)
      .accessibilityHint(
        "\(shortcut.detail)。\(shortcut.scopePresentation.accessibilityDescription)"
      )
      .accessibilityIdentifier("settings-task-shortcut-\(shortcut.id)")
    }
  }
}
