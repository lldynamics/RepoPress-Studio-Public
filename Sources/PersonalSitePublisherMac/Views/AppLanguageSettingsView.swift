import SwiftUI

struct AppLanguageSettingsView: View {
  @AppStorage(AppLanguagePreference.storageKey)
  private var appLanguage = AppLanguagePreference.system

  var body: some View {
    Form {
      Section("界面语言") {
        VStack(alignment: .leading, spacing: 8) {
          Text("语言")
            .font(.body)

          Picker("语言", selection: $appLanguage) {
            Text("跟随 macOS")
              .tag(AppLanguagePreference.system)
            Text("简体中文")
              .tag(AppLanguagePreference.simplifiedChinese)
            Text("English")
              .tag(AppLanguagePreference.english)
          }
          .pickerStyle(.radioGroup)
          .labelsHidden()
          .frame(maxWidth: .infinity, alignment: .leading)
          .accessibilityIdentifier("settings-app-language-picker")
        }

        Text(languageDescription)
          .font(.callout)
          .foregroundStyle(.secondary)
      }

      Section("应用方式") {
        LabeledContent("下次启动") {
          selectedLanguageLabel
            .foregroundStyle(.secondary)
        }

        Label {
          Text("语言更改会在下次启动 RepoPress 后统一生效。当前窗口、菜单栏和系统面板不会立即切换。")
        } icon: {
          Image(systemName: "arrow.clockwise.circle")
            .foregroundStyle(WorkbenchTheme.brand)
        }
        .font(.callout)
      }
    }
    .formStyle(.grouped)
    .padding(WorkbenchSpacing.content)
    .accessibilityIdentifier("app-language-settings")
  }

  private var languageDescription: LocalizedStringKey {
    switch appLanguage {
    case .system:
      return "下次启动后跟随 macOS 的应用语言设置。"
    case .simplifiedChinese:
      return "下次启动后 RepoPress 固定使用简体中文。"
    case .english:
      return "下次启动后 RepoPress 固定使用英文。"
    }
  }

  @ViewBuilder
  private var selectedLanguageLabel: some View {
    switch appLanguage {
    case .system:
      Text("跟随 macOS")
    case .simplifiedChinese:
      Text("简体中文")
    case .english:
      Text("English")
    }
  }
}
