import AppKit
import PublishingWorkbenchCore
import SwiftUI

/// The model catalog is owned by the authenticated App Server account. This
/// view deliberately renders only the models and effort levels returned by
/// `model/list`; it never maintains a plan-specific hard-coded list.
struct CodexAppServerModelSelectionSection: View {
  @Binding var model: String
  @Binding var reasoningEffortOverride: String?
  let models: [CodexAppServerModel]
  let isLoading: Bool
  let errorMessage: String?
  let onRefresh: () -> Void

  @State private var selectionMessage: String?

  var body: some View {
    Section("2. 模型与推理等级") {
      Picker("模型", selection: modelBinding) {
        Text("跟随账户默认")
          .tag(AIProviderPreset.codexDefaultModel)

        ForEach(models, id: \.id) { option in
          Text(modelTitle(option))
            .tag(option.model)
        }
      }
      .accessibilityLabel("ChatGPT 模型")
      .accessibilityIdentifier("settings-ai-codex-model-picker")

      if let selectedModel {
        if let description = selectedModel.description {
          Text(description)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      } else if isLoading {
        Label("正在加载账户可用模型…", systemImage: "arrow.triangle.2.circlepath")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else if let errorMessage {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Label(errorMessage, systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(WorkbenchTheme.warning)
          Spacer(minLength: 8)
          Button("重试", action: onRefresh)
            .buttonStyle(.borderless)
            .accessibilityIdentifier("settings-ai-codex-model-refresh")
        }
      } else {
        Text("账户暂未返回可用模型；可以点击刷新重试。")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      if selectedModel != nil, let errorMessage {
        Label("模型列表刷新失败：\(errorMessage)", systemImage: "exclamationmark.triangle")
          .font(.caption)
          .foregroundStyle(WorkbenchTheme.warning)
          .fixedSize(horizontal: false, vertical: true)
      }

      if let selectedModel, !selectedModel.supportedReasoningEfforts.isEmpty {
        Picker("推理等级", selection: effortBinding) {
          Text("跟随模型默认")
            .tag("")
          ForEach(selectedModel.supportedReasoningEfforts, id: \.reasoningEffort) { option in
            Text(effortTitle(option))
              .tag(option.reasoningEffort)
          }
        }
        .accessibilityLabel("ChatGPT 推理等级")
        .accessibilityIdentifier("settings-ai-codex-reasoning-picker")

        if let selectedEffortDescription {
          Text(selectedEffortDescription)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      } else {
        LabeledContent("推理等级", value: "跟随模型默认")
          .foregroundStyle(.secondary)
          .accessibilityHint("当前模型未声明可选推理等级")
          .accessibilityIdentifier("settings-ai-codex-reasoning-unavailable")
      }

      HStack(spacing: 10) {
        if isLoading {
          ProgressView()
            .controlSize(.small)
            .accessibilityLabel("正在刷新模型列表")
        }
        Button("刷新可用模型", action: onRefresh)
          .buttonStyle(.borderless)
          .disabled(isLoading)
          .accessibilityIdentifier("settings-ai-codex-model-refresh")
      }

      if let selectionMessage {
        AccessibleStatusMessage(
          message: selectionMessage,
          severity: .warning,
          movesAccessibilityFocusForUrgentStatus: false
        )
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("settings-ai-codex-model-selection")
    .onAppear {
      normalizeAndReconcileSelection()
    }
    .onChange(of: model) { _, _ in
      normalizeAndReconcileSelection()
    }
    .onChange(of: models) { _, _ in
      normalizeAndReconcileSelection()
    }
  }

  private var modelBinding: Binding<String> {
    Binding(
      get: { normalizedModel },
      set: { newValue in
        let normalized = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        model = normalized.isEmpty ? AIProviderPreset.codexDefaultModel : normalized
      }
    )
  }

  private var effortBinding: Binding<String> {
    Binding(
      get: { reasoningEffortOverride?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" },
      set: { newValue in
        let normalized = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        reasoningEffortOverride = normalized.isEmpty ? nil : normalized
        selectionMessage = nil
      }
    )
  }

  private var normalizedModel: String {
    let value = model.trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? AIProviderPreset.codexDefaultModel : value
  }

  private var selectedModel: CodexAppServerModel? {
    if normalizedModel == AIProviderPreset.codexDefaultModel {
      return models.first(where: \.isDefault) ?? models.first
    }
    return models.first(where: { $0.model == normalizedModel || $0.id == normalizedModel })
  }

  private var selectedEffortDescription: String? {
    guard let effort = reasoningEffortOverride?.trimmingCharacters(in: .whitespacesAndNewlines),
      !effort.isEmpty,
      let option = selectedModel?.supportedReasoningEfforts.first(where: {
        $0.reasoningEffort == effort
      })
    else {
      return nil
    }
    return option.description
  }

  private func normalizeAndReconcileSelection() {
    if model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      model = AIProviderPreset.codexDefaultModel
    }
    if models.isEmpty {
      guard !isLoading, errorMessage == nil else { return }
      if normalizedModel != AIProviderPreset.codexDefaultModel {
        model = AIProviderPreset.codexDefaultModel
        reasoningEffortOverride = nil
        selectionMessage = "当前账户没有返回已保存的模型，已切回账户默认模型。"
      }
      return
    }

    if normalizedModel != AIProviderPreset.codexDefaultModel, selectedModel == nil {
      model = AIProviderPreset.codexDefaultModel
      reasoningEffortOverride = nil
      selectionMessage = "已保存的模型不在当前套餐可用列表中，已切回账户默认模型。"
      return
    }

    guard let selectedModel else { return }
    if normalizedModel == selectedModel.id, normalizedModel != selectedModel.model {
      model = selectedModel.model
    }
    let effort = reasoningEffortOverride?.trimmingCharacters(in: .whitespacesAndNewlines)
    if let effort, !effort.isEmpty,
      !selectedModel.supportedReasoningEfforts.contains(where: {
        $0.reasoningEffort == effort
      })
    {
      reasoningEffortOverride = nil
      selectionMessage = "当前模型不支持已保存的推理等级，已切回模型默认。"
    }
  }

  private func modelTitle(_ model: CodexAppServerModel) -> String {
    model.localizedDisplayName == model.model
      ? model.localizedDisplayName
      : "\(model.localizedDisplayName) (\(model.model))"
  }

  private func effortTitle(_ option: CodexAppServerReasoningEffortOption) -> String {
    guard let description = option.description, !description.isEmpty else {
      return option.reasoningEffort
    }
    return "\(option.reasoningEffort) — \(description)"
  }
}

struct CodexAppServerRuntimeStatusContent: View {
  let runtimeStatus: CodexAppServerRuntimeStatus?
  let openInstallationGuide: () -> Void
  let copyInstallationCommand: () -> Void

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Label(
        runtimeTitle,
        systemImage: runtimeStatus?.isAvailable == true ? "cpu.fill" : "shippingbox"
      )
      .foregroundStyle(
        runtimeStatus?.isAvailable == true ? WorkbenchTheme.success : WorkbenchTheme.warning
      )
      Spacer()
      if runtimeStatus?.isAvailable == false {
        Button("打开安装说明", action: openInstallationGuide)
          .buttonStyle(.borderless)
        Button("复制安装命令", action: copyInstallationCommand)
          .buttonStyle(.borderless)
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("settings-ai-codex-runtime-status")

    if let path = runtimeStatus?.executableURL?.path {
      Text(path)
        .font(.workbenchMetadata.monospaced())
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
    } else if runtimeStatus != nil {
      Text("ChatGPT 登录需要本机 Codex 运行组件。安装后点“重新检测”；RepoPress 不会静默安装或修改系统。")
        .font(.workbenchMetadata)
        .foregroundStyle(.secondary)
    }
  }

  private var runtimeTitle: String {
    guard let runtimeStatus else { return String(localized: "正在检测运行组件…") }
    guard runtimeStatus.isAvailable else { return String(localized: "未找到 Codex 运行组件") }
    let version = runtimeStatus.version?.nilIfEmpty.map { " · \($0)" } ?? ""
    switch runtimeStatus.source {
    case .bundled:
      return String(localized: "内置运行组件可用") + version
    case .homebrew:
      return String(localized: "Homebrew 运行组件可用") + version
    case .path:
      return String(localized: "系统运行组件可用") + version
    case nil:
      return String(localized: "运行组件可用") + version
    }
  }
}

struct CodexAppServerDeviceCodeContent: View {
  let login: CodexAppServerDeviceCodeLoginResult
  let onCopy: () -> Void

  init(_ login: CodexAppServerDeviceCodeLoginResult, onCopy: @escaping () -> Void) {
    self.login = login
    self.onCopy = onCopy
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("在浏览器输入设备码")
        .font(.headline)
      Text(login.userCode)
        .font(.title3.monospaced().weight(.semibold))
        .textSelection(.enabled)
        .accessibilityLabel("设备码 \(login.userCode)")
      HStack(spacing: 10) {
        Button("复制设备码") {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(login.userCode, forType: .string)
          onCopy()
        }
        Button("打开验证页面") {
          _ = NSWorkspace.shared.open(login.verificationURL)
        }
      }
    }
    .padding(10)
    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("settings-ai-codex-device-code")
  }
}
