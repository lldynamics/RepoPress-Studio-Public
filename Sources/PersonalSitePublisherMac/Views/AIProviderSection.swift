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
  let applyCurrentPreset: () -> Void

  var body: some View {
    Picker("Preset", selection: presetBinding) {
      ForEach(AIProviderPreset.allCases) { preset in
        Text(preset.displayName).tag(preset)
      }
    }
    .accessibilityLabel("AI 服务预设")
    .accessibilityValue(presetDisplayName)

    Button {
      applyCurrentPreset()
    } label: {
      Label("应用当前预设", systemImage: "wand.and.stars")
    }
    .accessibilityLabel("应用当前 AI 预设")

    TextField("Base URL", text: baseURL)
      .accessibilityLabel("AI Base URL")
      .accessibilityValue(baseURLDisplayValue)

    TextField("Model", text: model)
      .accessibilityLabel("AI 模型")
      .accessibilityValue(modelDisplayValue)

    Toggle("需要 API Key", isOn: requiresAPIKeyBinding)
      .accessibilityLabel("AI 需要 API Key")
      .accessibilityValue(requiresAPIKeyDisplayValue)
  }
}
