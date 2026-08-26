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
    Section("ChatGPT 模型与推理深度") {
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
        systemImage: runtimeStatus?.isCompatible == true ? "cpu.fill" : "shippingbox"
      )
      .foregroundStyle(
        runtimeStatus?.isCompatible == true ? WorkbenchTheme.success : WorkbenchTheme.warning
      )
      Spacer()
      if runtimeStatus?.compatibility == .missingExecutable {
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
    }

    if let runtimeStatus, !runtimeStatus.isCompatible {
      Text(runtimeRecoveryHint(for: runtimeStatus))
        .font(.workbenchMetadata)
        .foregroundStyle(.secondary)
    }
  }

  private var runtimeTitle: String {
    guard let runtimeStatus else { return String(localized: "正在检测运行组件…") }
    switch runtimeStatus.compatibility {
    case .missingExecutable:
      return String(localized: "未找到 Codex 运行组件")
    case .missingVersion:
      return String(localized: "运行组件未返回版本号")
    case .unparseableVersion:
      return String(localized: "无法解析运行组件版本")
    case .unsupportedVersion:
      let version = runtimeStatus.parsedVersion?.description ?? ""
      return version.isEmpty
        ? String(localized: "运行组件版本过低")
        : String(localized: "运行组件版本过低") + " · " + version
    case .compatible:
      let version = runtimeStatus.parsedVersion.map { " · \($0)" } ?? ""
      switch runtimeStatus.source {
      case .homebrew:
        return String(localized: "Homebrew 运行组件可用") + version
      case .path:
        return String(localized: "系统运行组件可用") + version
      case nil:
        return String(localized: "运行组件可用") + version
      }
    }
  }

  private func runtimeRecoveryHint(for status: CodexAppServerRuntimeStatus) -> String {
    switch status.compatibility {
    case .missingExecutable:
      return String(localized: "ChatGPT 登录需要本机 Codex 运行组件。安装后点“重新检测”；RepoPress 不会静默安装或修改系统。")
    case .missingVersion:
      return String(localized: "Codex 运行组件未返回版本号。请更新 Codex 后点“重新检测”。")
    case .unparseableVersion:
      return String(localized: "无法确认 Codex 运行组件版本。请更新 Codex 后点“重新检测”。")
    case .unsupportedVersion:
      return String(localized: "当前 Codex 运行组件版本过低；请更新到 0.142.0 或更高版本后重新检测。")
    case .compatible:
      return ""
    }
  }
}

enum CodexAppServerConnectionTestState: Equatable {
  case idle
  case testing
  case passed
  case failed
}

private enum CodexAppServerSetupStepState {
  case blocked
  case current
  case complete

  var symbolName: String {
    switch self {
    case .blocked: return "exclamationmark.circle"
    case .current: return "arrow.right.circle"
    case .complete: return "checkmark.circle.fill"
    }
  }

  var color: Color {
    switch self {
    case .blocked: return WorkbenchTheme.warning
    case .current: return .secondary
    case .complete: return WorkbenchTheme.success
    }
  }
}

/// A compact, linear account setup summary. The buttons in the account section
/// remain the actions; this view makes their gating state visible first.
struct CodexAppServerAccountSetupSteps: View {
  let runtimeStatus: CodexAppServerRuntimeStatus?
  let accountStatus: CodexAppServerAccountStatus?
  let consentGranted: Bool
  let connectionTestState: CodexAppServerConnectionTestState

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      setupStep(
        number: 1,
        title: String(localized: "运行组件兼容性"),
        state: runtimeStep.state,
        detail: runtimeStep.detail
      )
      setupStep(
        number: 2,
        title: String(localized: "ChatGPT 账户"),
        state: accountStep.state,
        detail: accountStep.detail
      )
      setupStep(
        number: 3,
        title: String(localized: "内容发送授权"),
        state: consentStep.state,
        detail: consentStep.detail
      )
      setupStep(
        number: 4,
        title: String(localized: "连接测试"),
        state: connectionStep.state,
        detail: connectionStep.detail
      )
    }
    .padding(.vertical, 2)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("settings-ai-codex-setup-steps")
  }

  private var runtimeStep: (state: CodexAppServerSetupStepState, detail: String) {
    guard let runtimeStatus else {
      return (
        .current,
        String(localized: "正在检测 Codex 运行组件兼容性…")
      )
    }

    switch runtimeStatus.compatibility {
    case .missingExecutable:
      return (.blocked, String(localized: "未找到 Codex 运行组件。"))
    case .missingVersion:
      return (.blocked, String(localized: "运行组件未返回版本号"))
    case .unparseableVersion:
      return (.blocked, String(localized: "无法解析运行组件版本"))
    case .unsupportedVersion:
      let version = runtimeStatus.parsedVersion?.description ?? ""
      let detail =
        version.isEmpty
        ? String(localized: "运行组件版本过低")
        : "\(String(localized: "运行组件版本过低")) · \(version)"
      return (.blocked, detail)
    case .compatible:
      let version = runtimeStatus.parsedVersion?.description
      let detail =
        version.map {
          "\(String(localized: "Codex 运行组件已兼容")) · \($0)"
        } ?? String(localized: "Codex 运行组件已兼容")
      return (.complete, detail)
    }
  }

  private var accountStep: (state: CodexAppServerSetupStepState, detail: String) {
    guard runtimeStatus?.isCompatible == true else {
      return (.blocked, String(localized: "请先完成运行组件检查"))
    }
    guard let accountStatus else {
      return (.current, String(localized: "正在读取 ChatGPT 账户…"))
    }
    return accountStatus.isAuthenticated
      ? (.complete, String(localized: "已通过 ChatGPT 登录"))
      : (.current, String(localized: "尚未登录 ChatGPT"))
  }

  private var consentStep: (state: CodexAppServerSetupStepState, detail: String) {
    guard runtimeStatus?.isCompatible == true, accountStatus?.isAuthenticated == true else {
      return (.blocked, String(localized: "请先登录 ChatGPT"))
    }
    return consentGranted
      ? (.complete, String(localized: "内容发送已授权"))
      : (.current, String(localized: "登录后同意内容发送"))
  }

  private var connectionStep: (state: CodexAppServerSetupStepState, detail: String) {
    guard runtimeStatus?.isCompatible == true,
      accountStatus?.isAuthenticated == true,
      consentGranted
    else {
      return (.blocked, String(localized: "请先完成账户登录和内容授权"))
    }

    switch connectionTestState {
    case .idle:
      return (.current, String(localized: "连接测试尚未运行"))
    case .testing:
      return (.current, String(localized: "正在测试 ChatGPT 连接…"))
    case .passed:
      return (.complete, String(localized: "连接测试通过"))
    case .failed:
      return (.current, String(localized: "连接测试失败，请重试"))
    }
  }

  @ViewBuilder
  private func setupStep(
    number: Int,
    title: String,
    state: CodexAppServerSetupStepState,
    detail: String
  ) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Image(systemName: state.symbolName)
        .foregroundStyle(state.color)
        .frame(width: 16)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 1) {
        Text(title)
          .font(.subheadline.weight(.medium))
        Text(detail)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(number). \(title)：\(detail)")
    .accessibilityIdentifier("settings-ai-codex-setup-step-\(number)")
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
