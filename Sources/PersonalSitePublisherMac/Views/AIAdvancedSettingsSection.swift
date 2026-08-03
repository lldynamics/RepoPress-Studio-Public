import PublishingWorkbenchCore
import SwiftUI

struct AIAdvancedSettingsSection: View {
  @Binding var settings: AIProviderAdvancedSettings
  let reasoningSupport: AIProviderCapabilitySupport

  var body: some View {
    Section {
      VStack(alignment: .leading, spacing: 6) {
        HStack {
          Text("聊天自定义系统指令")
          Spacer()
          Text(
            verbatim: "\(settings.normalizedSystemPrompt.count)/\(AIProviderAdvancedSettings.maximumSystemPromptLength)"
          )
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }

        TextEditor(text: systemPromptBinding)
          .font(.body)
          .frame(minHeight: 72, maxHeight: 120)
          .padding(5)
          .background(
            Color.primary.opacity(0.035),
            in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
          )
          .overlay {
            RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
              .stroke(Color.primary.opacity(0.12), lineWidth: 1)
          }
          .accessibilityLabel("聊天自定义系统指令")
      }

      Toggle("自定义 Temperature", isOn: temperatureEnabledBinding)
      if settings.temperature != nil {
        LabeledContent("Temperature") {
          HStack(spacing: 10) {
            Slider(value: temperatureBinding, in: 0 ... 2, step: 0.1)
              .frame(minWidth: 180)
            Text(settings.normalizedTemperature ?? 0, format: .number.precision(.fractionLength(1)))
              .font(.callout.monospacedDigit())
              .frame(width: 30, alignment: .trailing)
          }
        }
      }

      Toggle("限制最大输出 Tokens", isOn: maximumTokensEnabledBinding)
      if settings.maximumOutputTokens != nil {
        LabeledContent("最大输出 Tokens") {
          Stepper(
            value: maximumTokensBinding,
            in: 256 ... AIProviderAdvancedSettings.maximumOutputTokenLimit,
            step: 256
          ) {
            Text(settings.normalizedMaximumOutputTokens ?? 0, format: .number)
              .font(.callout.monospacedDigit())
          }
        }
      }

      Picker("连接备用推理深度", selection: $settings.reasoningPreference) {
        ForEach(AIProviderReasoningPreference.allCases) { preference in
          Text(verbatim: preference.localizedTitle).tag(preference)
        }
      }
      .disabled(reasoningSupport == .unsupported)
      .accessibilityHint(reasoningAccessibilityHint)

      if !settings.isDefault {
        HStack {
          Spacer()
          Button("恢复自动参数") {
            settings = AIProviderAdvancedSettings()
          }
          .buttonStyle(.borderless)
        }
      }
    } header: {
      Text("高级对话参数")
    } footer: {
      Text("仅影响 AI 助手对话；会话内推理级别优先，服务商不接受的参数会自动移除。")
    }
  }

  private var systemPromptBinding: Binding<String> {
    Binding(
      get: { settings.systemPrompt },
      set: { settings.systemPrompt = String($0.prefix(AIProviderAdvancedSettings.maximumSystemPromptLength)) }
    )
  }

  private var temperatureEnabledBinding: Binding<Bool> {
    Binding(
      get: { settings.temperature != nil },
      set: { settings.temperature = $0 ? (settings.temperature ?? 0.7) : nil }
    )
  }

  private var temperatureBinding: Binding<Double> {
    Binding(
      get: { settings.normalizedTemperature ?? 0.7 },
      set: { settings.temperature = min(2, max(0, $0)) }
    )
  }

  private var maximumTokensEnabledBinding: Binding<Bool> {
    Binding(
      get: { settings.maximumOutputTokens != nil },
      set: { settings.maximumOutputTokens = $0 ? (settings.maximumOutputTokens ?? 4_096) : nil }
    )
  }

  private var maximumTokensBinding: Binding<Int> {
    Binding(
      get: { settings.normalizedMaximumOutputTokens ?? 4_096 },
      set: {
        settings.maximumOutputTokens = min(
          AIProviderAdvancedSettings.maximumOutputTokenLimit,
          max(256, $0)
        )
      }
    )
  }

  private var reasoningAccessibilityHint: String {
    reasoningSupport == .unsupported
      ? String(localized: "当前服务未声明推理调节能力")
      : String(localized: "实际支持范围取决于服务和模型")
  }
}
