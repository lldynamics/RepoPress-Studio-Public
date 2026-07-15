import PublishingWorkbenchCore
import SwiftUI

struct WorkspaceTaskNavigation: View {
  @ObservedObject var store: WorkbenchStore
  let isAIInspectorSelected: Bool
  let onSelectSection: (WorkspaceSection) -> Void
  let onOpenAIInspector: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      navigationGroup(title: WorkspaceArea.writing.localizedDisplayName) {
        sectionButton(.writing)
        aiAssistantButton
        sectionButton(.images)
      }

      navigationGroup(title: WorkspaceArea.publishing.localizedDisplayName) {
        sectionButton(.sync)
        sectionButton(.contentHealth)
      }
    }
    .padding(10)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("主任务导航")
    .accessibilityIdentifier("workspace-task-navigation")
  }

  private func navigationGroup<Content: View>(
    title: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title)
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)

      content()
    }
  }

  private func sectionButton(_ section: WorkspaceSection) -> some View {
    let isSelected = store.selectedSection == section
    return Button {
      onSelectSection(section)
    } label: {
      navigationLabel(
        workspaceNavigationLocalizedKey(section.displayNameLocalizationKey),
        systemImage: section.systemImage,
        isSelected: isSelected,
        isActiveAccessory: false
      )
    }
    .buttonStyle(.plain)
    .help(workspaceNavigationLocalizedString(section.displayNameLocalizationKey))
    .accessibilityLabel(workspaceNavigationLocalizedKey(section.displayNameLocalizationKey))
    .accessibilityAddTraits(isSelected ? .isSelected : [])
    .accessibilityIdentifier("workspace-sidebar-\(section.rawValue)")
  }

  private var aiAssistantButton: some View {
    Button(action: onOpenAIInspector) {
      navigationLabel(
        LocalizedStringKey("AI 助手"),
        systemImage: "sparkles",
        isSelected: false,
        isActiveAccessory: isAIInspectorSelected
      )
    }
    .buttonStyle(.plain)
    .help("在右侧 Inspector 中打开 AI 助手")
    .accessibilityLabel("打开 AI 助手")
    .accessibilityRemoveTraits(.isSelected)
    .accessibilityValue(isAIInspectorSelected ? "已打开" : "已关闭")
    .accessibilityIdentifier("workspace-sidebar-ai-assistant")
  }

  private func navigationLabel(
    _ title: LocalizedStringKey,
    systemImage: String,
    isSelected: Bool,
    isActiveAccessory: Bool
  ) -> some View {
    HStack(spacing: 9) {
      Image(systemName: systemImage)
        .frame(width: 16)
        .foregroundStyle(isSelected || isActiveAccessory ? WorkbenchTheme.primary : Color.secondary)

      Text(title)
        .lineLimit(1)

      Spacer(minLength: 8)

      if isActiveAccessory {
        Image(systemName: "checkmark")
          .font(.caption.weight(.semibold))
          .foregroundStyle(WorkbenchTheme.primary)
          .accessibilityHidden(true)
      }
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 7)
    .frame(maxWidth: .infinity, alignment: .leading)
    .foregroundStyle(Color.primary)
    .background {
      if isSelected {
        RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
          .fill(WorkbenchTheme.primary.opacity(WorkbenchOpacity.accentBackground))
      }
    }
    .contentShape(Rectangle())
  }
}
