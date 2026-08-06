import SwiftUI

struct AppearanceSettingsView: View {
  @AppStorage(WorkbenchAccentPalette.storageKey)
  private var accentPaletteRawValue = WorkbenchAccentPalette.system.rawValue

  private var selectedPalette: WorkbenchAccentPalette {
    WorkbenchAccentPalette.resolved(rawValue: accentPaletteRawValue)
  }

  var body: some View {
    Form {
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
    .accessibilityIdentifier("appearance-settings")
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

        HStack(spacing: 12) {
          Button("主要按钮") {}
            .buttonStyle(.borderedProminent)
            .tint(selectedPalette.color)

          Button("次要操作") {}
            .buttonStyle(.bordered)
            .tint(selectedPalette.color)

          Label("选中状态", systemImage: "checkmark.circle.fill")
            .font(.caption.weight(.medium))
            .foregroundStyle(selectedPalette.color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(selectedPalette.color.opacity(0.12), in: Capsule())
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
        .overlay(
          RoundedRectangle(cornerRadius: 8)
            .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        )
      }
      .padding(.top, 4)
    }
  }
}
