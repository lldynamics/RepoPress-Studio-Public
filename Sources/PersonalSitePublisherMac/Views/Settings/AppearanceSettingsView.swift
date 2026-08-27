import SwiftUI

struct AppearanceSettingsView: View {
  let autoRunPreflightBinding: Binding<Bool>
  @Binding var scanRepositoryOnLaunch: Bool

  @AppStorage(WorkbenchAccentPalette.storageKey)
  private var accentPaletteRawValue = WorkbenchAccentPalette.system.rawValue
  @State private var showsGlobalFrontMatterPreset = false

  private var selectedPalette: WorkbenchAccentPalette {
    WorkbenchAccentPalette.resolved(rawValue: accentPaletteRawValue)
  }

  var body: some View {
    Form {
      DefaultRuleGeneralSection(
        autoRunPreflightBinding: autoRunPreflightBinding,
        scanRepositoryOnLaunch: $scanRepositoryOnLaunch
      )
      globalFrontMatterSection
      appearanceSection
      AppLanguageSettingsView(isEmbedded: true)
    }
    .formStyle(.grouped)
    .padding(WorkbenchSpacing.content)
    .tint(selectedPalette.color)
    .onAppear {
      if accentPaletteRawValue != selectedPalette.rawValue {
        accentPaletteRawValue = selectedPalette.rawValue
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("appearance-settings")
  }

  private var globalFrontMatterSection: some View {
    Section {
      DisclosureGroup(
        String(localized: "全局 Front Matter 预设"),
        isExpanded: $showsGlobalFrontMatterPreset
      ) {
        Text("此预设适用于所有站点的新文章；站点专属的作者、标签、分类和路径仍在“内容与路径”中设置。")
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        DefaultRuleCustomFrontMatterSection()
          .padding(.top, 4)
      }
      .accessibilityIdentifier("settings-global-front-matter-preset")
    } header: {
      Text("新建文章默认")
    }
  }

  private var appearanceSection: some View {
    Section("主题强调色") {
      Text("默认跟随 macOS，也可以选择一个专属颜色。")
        .font(.callout)
        .foregroundStyle(.secondary)

      Picker("主题强调色", selection: $accentPaletteRawValue) {
        ForEach(WorkbenchAccentPalette.allCases) { palette in
          HStack(spacing: WorkbenchSpacing.control) {
            Circle()
              .fill(palette.color)
              .frame(width: 14, height: 14)
              .overlay {
                Circle()
                  .strokeBorder(Color.primary.opacity(0.16), lineWidth: 1)
              }
              .accessibilityHidden(true)

            Text(palette.title)
          }
          .tag(palette.rawValue)
        }
      }
      .pickerStyle(.radioGroup)
      .labelsHidden()
      .frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityIdentifier("settings-accent-color-picker")

      Label {
        Text("此颜色会立即应用到所有工作台窗口，并在下次启动时保留。")
      } icon: {
        Image(systemName: "paintpalette.fill")
          .foregroundStyle(selectedPalette.color)
      }
      .font(.callout)

      VStack(alignment: .leading, spacing: 8) {
        Text("界面效果预览")
          .font(.subheadline.weight(.semibold))

        ViewThatFits(in: .horizontal) {
          HStack(spacing: WorkbenchSpacing.card) {
            appearancePreviewElements
          }

          VStack(alignment: .leading, spacing: WorkbenchSpacing.control) {
            appearancePreviewElements
          }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
        .overlay(
          RoundedRectangle(cornerRadius: 8)
            .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("主题强调色预览")
        .accessibilityValue("主要操作、次要操作和选中状态的颜色示例")
      }
      .padding(.top, 4)
    }
  }

  @ViewBuilder
  private var appearancePreviewElements: some View {
    ForEach(AppearancePreviewElement.allCases) { element in
      switch element {
      case .primaryAction:
        Text(element.title)
          .font(.workbenchButtonLabel)
          .foregroundStyle(Color(nsColor: .alternateSelectedControlTextColor))
          .padding(.horizontal, 12)
          .padding(.vertical, 5)
          .background(
            selectedPalette.color,
            in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
          )
      case .secondaryAction:
        Text(element.title)
          .font(.workbenchButtonLabel)
          .foregroundStyle(selectedPalette.color)
          .padding(.horizontal, 12)
          .padding(.vertical, 5)
          .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
          )
          .overlay {
            RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
              .strokeBorder(selectedPalette.color.opacity(0.6), lineWidth: 1)
          }
      case .selection:
        Label(element.title, systemImage: "checkmark.circle.fill")
          .font(.caption.weight(.medium))
          .foregroundStyle(selectedPalette.color)
          .padding(.horizontal, 8)
          .padding(.vertical, 4)
          .background(selectedPalette.color.opacity(0.12), in: Capsule())
      }
    }
  }
}

enum AppearancePreviewElement: String, CaseIterable, Identifiable {
  case primaryAction
  case secondaryAction
  case selection

  var id: String { rawValue }

  var title: LocalizedStringKey {
    switch self {
    case .primaryAction:
      "主要按钮"
    case .secondaryAction:
      "次要操作"
    case .selection:
      "选中状态"
    }
  }

}
