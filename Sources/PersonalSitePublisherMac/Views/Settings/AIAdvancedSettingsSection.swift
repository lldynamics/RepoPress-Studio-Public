import PublishingAICore
import PublishingCoreSupport
import SwiftUI

struct AIAdvancedSettingsSection: View {
  @Binding var settings: AIProviderAdvancedSettings
  let reasoningSupport: AIProviderCapabilitySupport
  let usesCodexAppServer: Bool
  var subsectionAnchor: SettingsSubsection? = nil
  /// The settings navigator can provide this binding to expand the disclosure before scrolling.
  var isExpanded: Binding<Bool>? = nil

  @State private var localDisclosureExpanded = false

  var body: some View {
    Section {
      DisclosureGroup(isExpanded: disclosureBinding) {
        if !usesCodexAppServer {
          networkProxyContent
        }
        conversationGenerationContent
      } label: {
        Label("高级 AI 设置", systemImage: "slider.horizontal.3")
          .accessibilityIdentifier("settings-ai-advanced-disclosure")
      }
    } header: {
      Text("参数与网络")
        .settingsSubsectionAnchor(subsectionAnchor)
    }
  }

  private var disclosureBinding: Binding<Bool> {
    isExpanded ?? $localDisclosureExpanded
  }

  private var networkProxyContent: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("网络代理 (Network Proxy)").font(.headline)
      Text("此代理仅对当前连接的 AI 网络请求生效。")
        .font(.caption)
        .foregroundStyle(.secondary)
      Toggle("配置 AI 独立网络代理", isOn: proxyEnabledBinding)
        .accessibilityIdentifier("settings-ai-proxy-toggle")
      if settings.proxyURL != nil {
        TextField(
          "代理地址 (如 http://127.0.0.1:7890 或 socks5://127.0.0.1:7890)",
          text: proxyURLBinding
        )
        .font(.body.monospaced())
        .accessibilityLabel(
          String(localized: "代理地址 (如 http://127.0.0.1:7890 或 socks5://127.0.0.1:7890)")
        )
        .accessibilityIdentifier("settings-ai-proxy-url-input")
      }
    }
  }

  private var conversationGenerationContent: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("模型生成与推理参数").font(.headline)
      Text("以下设置仅对当前连接的聊天生成生效。")
        .font(.caption)
        .foregroundStyle(.secondary)
      if usesCodexAppServer {
        Label("ChatGPT 模型与推理等级在上方账户区设置。", systemImage: "slider.horizontal.3")
          .font(.caption)
          .foregroundStyle(.secondary)
          .accessibilityIdentifier("settings-ai-codex-reasoning-location")
      } else {
        Picker("思考深度 (Reasoning Effort)", selection: $settings.reasoningPreference) {
          ForEach(AIProviderReasoningPreference.allCases) { preference in
            Text(verbatim: preference.localizedTitle).tag(preference)
          }
        }
        .disabled(reasoningSupport == .unsupported)
        .accessibilityHint(reasoningAccessibilityHint)
        Toggle("自定义 Temperature (温度)", isOn: temperatureEnabledBinding)
        if settings.temperature != nil {
          VStack(alignment: .leading, spacing: 4) {
            LabeledContent("Temperature") {
              HStack(spacing: 10) {
                Slider(value: temperatureBinding, in: 0...2, step: 0.1)
                  .frame(minWidth: 180)
                Text(
                  settings.normalizedTemperature ?? 0, format: .number.precision(.fractionLength(1))
                )
                .font(.callout.monospacedDigit())
                .frame(width: 30, alignment: .trailing)
              }
            }
            HStack {
              Text("0.0 精确严谨").font(.workbenchMetadata).foregroundStyle(.secondary)
              Spacer()
              Text("0.7 平衡默认").font(.workbenchMetadata).foregroundStyle(.secondary)
              Spacer()
              Text("2.0 创意发散").font(.workbenchMetadata).foregroundStyle(.secondary)
            }
          }
        }
        Toggle("限制最大输出 Tokens", isOn: maximumTokensEnabledBinding)
        if settings.maximumOutputTokens != nil {
          LabeledContent("最大输出 Tokens") {
            Stepper(
              value: maximumTokensBinding,
              in: 256...AIProviderAdvancedSettings.maximumOutputTokenLimit, step: 256
            ) {
              Text(settings.normalizedMaximumOutputTokens ?? 0, format: .number)
                .font(.callout.monospacedDigit())
            }
          }
        }
      }
      systemPromptContent
      if hasConversationParameterOverrides {
        HStack {
          Spacer()
          Button("恢复自动参数") {
            settings = AIProviderAdvancedSettings(
              allowsApplicationTools: settings.allowsApplicationTools,
              agentPermissionPolicy: settings.agentPermissionPolicy,
              proxyURL: settings.proxyURL,
              fallbackProfileID: settings.fallbackProfileID
            )
          }
          .buttonStyle(.borderless)
        }
      }
    }
  }

  private var systemPromptContent: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text("聊天自定义系统指令")
        Spacer()
        Text(
          verbatim:
            "\(settings.normalizedSystemPrompt.count)/\(AIProviderAdvancedSettings.maximumSystemPromptLength)"
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
  }

  private var hasConversationParameterOverrides: Bool {
    !settings.normalizedSystemPrompt.isEmpty
      || (!usesCodexAppServer && settings.normalizedTemperature != nil)
      || (!usesCodexAppServer && settings.normalizedMaximumOutputTokens != nil)
      || (!usesCodexAppServer && settings.reasoningPreference != .automatic)
  }

  private var systemPromptBinding: Binding<String> {
    Binding(
      get: { settings.systemPrompt },
      set: {
        settings.systemPrompt = String(
          $0.prefix(AIProviderAdvancedSettings.maximumSystemPromptLength))
      })
  }

  private var temperatureEnabledBinding: Binding<Bool> {
    Binding(
      get: { settings.temperature != nil },
      set: {
        settings.temperature = $0 ? (settings.temperature ?? 0.7) : nil
      })
  }

  private var temperatureBinding: Binding<Double> {
    Binding(
      get: { settings.normalizedTemperature ?? 0.7 },
      set: {
        settings.temperature = min(2, max(0, $0))
      })
  }

  private var maximumTokensEnabledBinding: Binding<Bool> {
    Binding(
      get: { settings.maximumOutputTokens != nil },
      set: {
        settings.maximumOutputTokens = $0 ? (settings.maximumOutputTokens ?? 4_096) : nil
      })
  }

  private var maximumTokensBinding: Binding<Int> {
    Binding(
      get: { settings.normalizedMaximumOutputTokens ?? 4_096 },
      set: {
        settings.maximumOutputTokens = min(
          AIProviderAdvancedSettings.maximumOutputTokenLimit,
          max(256, $0)
        )
      })
  }

  private var reasoningAccessibilityHint: String {
    reasoningSupport == .unsupported
      ? String(localized: "当前服务未声明推理调节能力")
      : String(localized: "实际支持范围取决于服务和模型")
  }

  private var proxyEnabledBinding: Binding<Bool> {
    Binding(
      get: { settings.proxyURL != nil },
      set: {
        settings.proxyURL = $0 ? (settings.proxyURL ?? "http://127.0.0.1:7890") : nil
      })
  }

  private var proxyURLBinding: Binding<String> {
    Binding(
      get: { settings.proxyURL ?? "" },
      set: {
        settings.proxyURL = $0.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
      })
  }
}
