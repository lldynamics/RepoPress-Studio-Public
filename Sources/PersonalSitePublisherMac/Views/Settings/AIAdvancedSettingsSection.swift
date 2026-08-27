import PublishingWorkbenchCore
import SwiftUI

struct AIAdvancedSettingsSection: View {
  @Binding var settings: AIProviderAdvancedSettings
  let reasoningSupport: AIProviderCapabilitySupport
  let usesCodexAppServer: Bool

  var body: some View {
    if !usesCodexAppServer {
      Section("网络代理 (Network Proxy)") {
        Toggle("配置 AI 独立网络代理", isOn: proxyEnabledBinding)
          .accessibilityIdentifier("settings-ai-proxy-toggle")

        if settings.proxyURL != nil {
          VStack(alignment: .leading, spacing: 4) {
            TextField(
              "代理地址 (如 http://127.0.0.1:7890 或 socks5://127.0.0.1:7890)",
              text: proxyURLBinding
            )
            .font(.body.monospaced())
            .accessibilityLabel(
              String(localized: "代理地址 (如 http://127.0.0.1:7890 或 socks5://127.0.0.1:7890)")
            )
            .accessibilityIdentifier("settings-ai-proxy-url-input")

            Text("仅对当前 AI 网络请求生效，用于解决海外模型服务网络连通问题。")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      }
    }

    Section("模型生成与推理参数") {
      Toggle("允许 AI 使用应用内工具 (Agent)", isOn: allowsApplicationToolsBinding)
        .accessibilityIdentifier("settings-ai-agent-tools-toggle")
      Text(applicationToolsDescription)
        .font(.caption)
        .foregroundStyle(.secondary)

      VStack(alignment: .leading, spacing: 8) {
        Text("Agent 权限范围 (Agent Permissions)")
          .font(.headline)
        Text(agentPermissionSummary)
          .font(.caption)
          .foregroundStyle(.secondary)

        ForEach(AIAgentPermissionScope.allCases) { scope in
          VStack(alignment: .leading, spacing: 3) {
            Toggle(
              LocalizedStringKey(scope.localizedTitle),
              isOn: agentPermissionBinding(for: scope)
            )
            .disabled(!settings.resolvedAllowsApplicationTools)
            .accessibilityIdentifier("settings-ai-agent-permission-\(scope.rawValue)")

            Text(LocalizedStringKey(scope.localizedDescription))
              .font(.caption)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }

        if hasAgentPermissionOverrides {
          HStack {
            Spacer()
            Button("恢复默认 Agent 权限") {
              settings.agentPermissionPolicy = nil
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier("settings-ai-agent-permission-reset")
          }
        }
      }

      if usesCodexAppServer {
        Label(
          "ChatGPT 模型与推理等级在上方账户区设置。",
          systemImage: "slider.horizontal.3"
        )
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
      }

      if !usesCodexAppServer {
        Toggle("自定义 Temperature (温度)", isOn: temperatureEnabledBinding)
        if settings.temperature != nil {
          VStack(alignment: .leading, spacing: 4) {
            LabeledContent("Temperature") {
              HStack(spacing: 10) {
                Slider(value: temperatureBinding, in: 0...2, step: 0.1)
                  .frame(minWidth: 180)
                Text(
                  settings.normalizedTemperature ?? 0,
                  format: .number.precision(.fractionLength(1))
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
              in: 256...AIProviderAdvancedSettings.maximumOutputTokenLimit,
              step: 256
            ) {
              Text(settings.normalizedMaximumOutputTokens ?? 0, format: .number)
                .font(.callout.monospacedDigit())
            }
          }
        }
      }

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

    Section("全局系统提示词 (System Prompt)") {
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
  }

  private var allowsApplicationToolsBinding: Binding<Bool> {
    Binding(
      get: { settings.resolvedAllowsApplicationTools },
      set: { settings.allowsApplicationTools = $0 }
    )
  }

  private var applicationToolsDescription: String {
    settings.resolvedAllowsApplicationTools
      ? String(localized: "开启后，支持的连接可以调用已勾选权限内的应用内工具；新建空白文章可直接执行，内容修改、删除、仓库写入和发布仍需单独确认。")
      : String(localized: "关闭后仅使用普通文本对话，不会声明或执行应用内工具。")
  }

  private var agentPermissionSummary: String {
    settings.resolvedAllowsApplicationTools
      ? String(localized: "仅允许下方已勾选的 Agent 权限；关闭总开关后所有权限都会暂时禁用。")
      : String(localized: "Agent 总开关已关闭。下方权限保留当前选择，但暂时全部禁用。")
  }

  private var hasAgentPermissionOverrides: Bool {
    settings.agentPermissionPolicy != nil
      && !settings.resolvedAgentPermissionPolicy.isDefault
  }

  private func agentPermissionBinding(
    for scope: AIAgentPermissionScope
  ) -> Binding<Bool> {
    Binding(
      get: { settings.resolvedAgentPermissionPolicy.allows(scope) },
      set: { isAllowed in
        var policy = settings.resolvedAgentPermissionPolicy
        policy.setAllowed(isAllowed, for: scope)
        settings.agentPermissionPolicy = policy
      }
    )
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
      }
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

  private var proxyEnabledBinding: Binding<Bool> {
    Binding(
      get: { settings.proxyURL != nil },
      set: { settings.proxyURL = $0 ? (settings.proxyURL ?? "http://127.0.0.1:7890") : nil }
    )
  }

  private var proxyURLBinding: Binding<String> {
    Binding(
      get: { settings.proxyURL ?? "" },
      set: { settings.proxyURL = $0.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty }
    )
  }
}
