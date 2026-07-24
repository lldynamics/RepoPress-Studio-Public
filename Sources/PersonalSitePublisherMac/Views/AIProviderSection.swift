import PublishingWorkbenchCore
import SwiftUI

struct AIProviderSection: View {
  let presetBinding: Binding<AIProviderPreset>
  let presetDisplayName: String
  let baseURL: Binding<String>
  let baseURLDisplayValue: String
  let model: Binding<String>
  let modelDisplayValue: String
  let requiresAPIKeyBinding: Binding<Bool>
  let requiresAPIKeyDisplayValue: String
  @State private var showsConnectionDetails = false

  var body: some View {
    Section(String(localized: "AI 服务")) {
      Picker(String(localized: "服务预设"), selection: presetBinding) {
        ForEach(AIProviderPreset.allCases) { preset in
          Text(preset.localizedDisplayName).tag(preset)
        }
      }
      .accessibilityLabel("AI 服务预设")
      .accessibilityValue(presetDisplayName)

      DisclosureGroup(String(localized: "自定义连接"), isExpanded: $showsConnectionDetails) {
        TextField(String(localized: "API 基础地址"), text: baseURL)
          .accessibilityLabel("AI Base URL")
          .accessibilityValue(baseURLDisplayValue)

        TextField(String(localized: "模型"), text: model)
          .accessibilityLabel("AI 模型")
          .accessibilityValue(modelDisplayValue)

        Toggle(String(localized: "需要 API 密钥"), isOn: requiresAPIKeyBinding)
          .accessibilityLabel("AI 需要 API Key")
          .accessibilityValue(requiresAPIKeyDisplayValue)
      }
    }
  }
}
