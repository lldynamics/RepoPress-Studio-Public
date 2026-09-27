import SwiftUI

struct WorkspaceModuleSettingsSection: View {
  @Binding var visibility: WorkspaceModuleVisibility

  var body: some View {
    Section {
      VStack(spacing: 0) {
        moduleToggle(
          title: "RSS",
          subtitle: "订阅和阅读 RSS；关闭后暂停定期刷新。",
          isOn: $visibility.rssEnabled,
          identifier: "settings-module-rss-toggle"
        )
        Divider()
        moduleToggle(
          title: "资料库",
          subtitle: "收集资料与笔记；关闭后同时隐藏菜单栏速记。",
          isOn: $visibility.libraryEnabled,
          identifier: "settings-module-library-toggle"
        )
        Divider()
        moduleToggle(
          title: "图片",
          subtitle: "管理图片资源；文章中的插图和封面编辑仍可使用。",
          isOn: $visibility.imagesEnabled,
          identifier: "settings-module-images-toggle"
        )
      }
    } header: {
      Text("功能模块")
        .settingsSubsectionAnchor(.appearanceModules)
    } footer: {
      Text("关闭后隐藏入口和相关命令；已有数据保留，可随时重新开启。")
    }
  }

  @ViewBuilder
  private func moduleToggle(
    title: LocalizedStringKey,
    subtitle: LocalizedStringKey,
    isOn: Binding<Bool>,
    identifier: String
  ) -> some View {
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .center, spacing: WorkbenchSpacing.page) {
        label(title: title, subtitle: subtitle)
          .frame(width: 220, alignment: .leading)
        Spacer(minLength: WorkbenchSpacing.card)
        Toggle(title, isOn: isOn)
          .labelsHidden()
          .accessibilityLabel(title)
          .accessibilityIdentifier(identifier)
      }

      HStack(alignment: .top, spacing: WorkbenchSpacing.page) {
        label(title: title, subtitle: subtitle)
        Spacer(minLength: WorkbenchSpacing.card)
        Toggle(title, isOn: isOn)
          .labelsHidden()
          .accessibilityLabel(title)
          .accessibilityIdentifier(identifier)
      }
    }
    .padding(.vertical, 18)
  }

  private func label(title: LocalizedStringKey, subtitle: LocalizedStringKey) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title).font(.body.weight(.semibold))
      Text(subtitle)
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}
