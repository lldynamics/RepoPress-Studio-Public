import SwiftUI

struct AppearanceSettingsView: View {
  @AppStorage(WorkbenchAccentPalette.storageKey)
  private var accentPaletteRawValue = WorkbenchAccentPalette.system.rawValue

  private var selectedPalette: WorkbenchAccentPalette {
    WorkbenchAccentPalette.resolved(rawValue: accentPaletteRawValue)
  }

  var body: some View {
    Form {
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
      }
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
}
