import AppKit
import PublishingAICore
import PublishingCoreSupport
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
  let connectionProfileID: UUID
  let discoverModels: (UUID, AIProviderConfig) async throws -> [AIModelDescriptor]
  let modelDiscoveryTrigger: UUID?
  let modelDiscoveryAuthorizationMessage: String?
  let modelDiscoveryInvalidation: UUID?
  let restorePresetDefaults: () -> Void
  let onContinueToVerification: () -> Void
  @State private var baseURLDraft: String
  @State private var discoveredModels: [AIModelDescriptor] = []
  @State private var isDiscoveringModels = false
  @State private var discoveryErrorMessage: String?
  @State private var modelDiscoveryTask: Task<Void, Never>?
  @State private var modelDiscoveryRequestID = UUID()
  @State private var isSearchPopoverPresented = false
  @State private var hasLoadedModels = false
  @State private var isConnectionFieldsExpanded = false

  init(
    presetBinding: Binding<AIProviderPreset>,
    presetDisplayName: String,
    baseURL: Binding<String>,
    baseURLDisplayValue: String,
    model: Binding<String>,
    modelDisplayValue: String,
    requiresAPIKeyBinding: Binding<Bool>,
    requiresAPIKeyDisplayValue: String,
    connectionProfileID: UUID,
    discoverModels: @escaping (UUID, AIProviderConfig) async throws -> [AIModelDescriptor],
    modelDiscoveryTrigger: UUID? = nil,
    modelDiscoveryAuthorizationMessage: String? = nil,
    modelDiscoveryInvalidation: UUID? = nil,
    restorePresetDefaults: @escaping () -> Void,
    onContinueToVerification: @escaping () -> Void
  ) {
    self.presetBinding = presetBinding
    self.presetDisplayName = presetDisplayName
    self.baseURL = baseURL
    self.baseURLDisplayValue = baseURLDisplayValue
    self.model = model
    self.modelDisplayValue = modelDisplayValue
    self.requiresAPIKeyBinding = requiresAPIKeyBinding
    self.requiresAPIKeyDisplayValue = requiresAPIKeyDisplayValue
    self.connectionProfileID = connectionProfileID
    self.discoverModels = discoverModels
    self.modelDiscoveryTrigger = modelDiscoveryTrigger
    self.modelDiscoveryAuthorizationMessage = modelDiscoveryAuthorizationMessage
    self.modelDiscoveryInvalidation = modelDiscoveryInvalidation
    self.restorePresetDefaults = restorePresetDefaults
    self.onContinueToVerification = onContinueToVerification
    _baseURLDraft = State(initialValue: baseURL.wrappedValue)
  }

  var body: some View {
    Section {
      Picker(String(localized: "连接方式"), selection: connectionKindBinding) {
        ForEach(AIConnectionKind.allCases) { kind in
          Label(kind.title, systemImage: kind.systemImage).tag(kind)
        }
      }
      .pickerStyle(.segmented)
      .accessibilityLabel(String(localized: "AI 连接方式"))
      .accessibilityValue(AIConnectionKind(preset: presetBinding.wrappedValue).title)
      .accessibilityIdentifier("settings-ai-connection-kind")

      if AIConnectionKind(preset: presetBinding.wrappedValue) == .apiKey {
        Picker(String(localized: "API 服务"), selection: presetBinding) {
          ForEach(apiKeyPresets) { preset in
            Text(preset.localizedDisplayName).tag(preset)
          }
        }
        .accessibilityLabel(String(localized: "API 服务预设"))
        .accessibilityValue(presetDisplayName)
        .accessibilityIdentifier("settings-ai-provider-preset")
      }

      if presetBinding.wrappedValue == .codexAppServer {
        LabeledContent(
          "连接方式",
          value: String(localized: "ChatGPT 套餐")
        )
        LabeledContent("模型", value: codexModelDisplayValue)
        Label("无需 API Key", systemImage: "person.crop.circle.badge.checkmark")
          .foregroundStyle(WorkbenchTheme.success)
      } else {
        if fieldPresentation.showsConnectionFieldsByDefault {
          connectionFields
        } else {
          DisclosureGroup("高级与自定义地址", isExpanded: $isConnectionFieldsExpanded) {
            connectionFields
          }
          .disclosureGroupStyle(
            WorkbenchDisclosureGroupStyle(toggleIdentifier: "settings-ai-provider-advanced")
          )
        }

        modelField
      }

      if isPresetModifiedFromDefault {
        HStack {
          Spacer()
          Button(String(localized: "恢复为预设默认值")) {
            restorePresetDefaults()
          }
          .font(.caption)
          .buttonStyle(.borderless)
        }
      }
    } header: {
      Text(String(localized: "选择 AI 连接方式"))
    } footer: {
      if presetBinding.wrappedValue == .codexAppServer {
        Text("使用自己的 ChatGPT 套餐，不需要 API Key；RepoPress 不读取或保存账户令牌。")
      } else if presetBinding.wrappedValue == .local {
        Text("内容只发送到这台 Mac 上配置的本地模型服务。")
      } else if presetBinding.wrappedValue == .custom {
        Text(String(localized: "自定义模式下，基础地址与模型默认为空。基础地址会在点击“应用地址”后生效，避免编辑过程中提前替换当前 AI 凭据。"))
      }
    }
    .onChange(of: baseURL.wrappedValue) { _, newValue in
      baseURLDraft = newValue
      invalidateModelDiscovery()
    }
    .onChange(of: modelDiscoveryTrigger) { _, _ in
      if canDiscoverModels { fetchModelsFromAPI() }
    }
    .onChange(of: modelDiscoveryInvalidation) { _, _ in
      invalidateModelDiscovery()
    }
    .onChange(of: modelDiscoveryAuthorizationMessage) { _, message in
      if message != nil { invalidateModelDiscovery() }
    }
    .onChange(of: requiresAPIKeyBinding.wrappedValue) { _, _ in
      invalidateModelDiscovery()
    }
    .onChange(of: model.wrappedValue) { _, _ in
      if isDiscoveringModels { invalidateModelDiscovery() }
    }
    .onChange(of: presetBinding.wrappedValue) { _, _ in
      invalidateModelDiscovery()
    }
    .onChange(of: connectionProfileID) { _, _ in
      baseURLDraft = baseURL.wrappedValue
      invalidateModelDiscovery()
    }
    .onDisappear {
      invalidateModelDiscovery()
    }
  }

  private var fieldPresentation: AIProviderFieldPresentation {
    AIProviderFieldPresentation(
      config: AIProviderConfig(
        preset: presetBinding.wrappedValue, baseURL: baseURL.wrappedValue,
        model: model.wrappedValue, requiresAPIKey: requiresAPIKeyBinding.wrappedValue))
  }

  private var connectionFields: some View {
    VStack(alignment: .leading, spacing: WorkbenchSpacing.control) {
      baseURLField
      Toggle(String(localized: "需要 API 密钥"), isOn: requiresAPIKeyBinding)
        .accessibilityLabel(String(localized: "AI 需要 API Key"))
        .accessibilityValue(requiresAPIKeyDisplayValue)
    }
  }

  private var connectionKindBinding: Binding<AIConnectionKind> {
    Binding(
      get: { AIConnectionKind(preset: presetBinding.wrappedValue) },
      set: { kind in
        switch kind {
        case .chatGPT:
          presetBinding.wrappedValue = .codexAppServer
        case .local:
          presetBinding.wrappedValue = .local
        case .apiKey:
          if !apiKeyPresets.contains(presetBinding.wrappedValue) {
            presetBinding.wrappedValue = .openAICompatible
          }
        }
      }
    )
  }

  private var apiKeyPresets: [AIProviderPreset] {
    [
      .openAICompatible,
      .deepSeek,
      .anthropic,
      .gemini,
      .siliconFlow,
      .moonshot,
      .zhipu,
      .openRouter,
      .custom,
    ]
  }

  private var codexModelDisplayValue: String {
    let value = model.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty || value == AIProviderPreset.codexDefaultModel
      ? String(localized: "跟随账户默认")
      : value
  }

  private var isPresetModifiedFromDefault: Bool {
    let preset = presetBinding.wrappedValue
    guard preset != .custom, preset != .codexAppServer else { return false }
    return baseURLDraft != preset.defaultBaseURL
      || model.wrappedValue != preset.defaultModel
  }

  private var hasUnappliedBaseURL: Bool {
    baseURLDraft.trimmingCharacters(in: .whitespacesAndNewlines)
      != baseURL.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var baseURLField: some View {
    VStack(alignment: .leading, spacing: 4) {
      ZStack(alignment: .trailing) {
        TextField(
          String(localized: "API 基础地址"),
          text: $baseURLDraft
        )
        .padding(.trailing, WorkbenchSpacing.spacious)
        .textContentType(.URL)
        .accessibilityLabel(String(localized: "AI Base URL"))
        .accessibilityValue(baseURLDraft.nilIfEmpty ?? String(localized: "未填写"))
        .accessibilityIdentifier("settings-ai-base-url")

        if !baseURLDraft.trimmedForPublishing.isEmpty {
          Button {
            baseURLDraft = ""
          } label: {
            Image(systemName: "xmark.circle.fill")
              .foregroundStyle(.secondary)
          }
          .buttonStyle(.plain)
          .help(String(localized: "清空 API 基础地址"))
          .accessibilityLabel(String(localized: "清空 AI Base URL"))
          .accessibilityIdentifier("ai-base-url-clear")
        }
      }

      HStack(spacing: 10) {
        Button(String(localized: "粘贴剪贴板地址")) {
          pasteBaseURLFromClipboard()
        }
        .font(.workbenchMetadata)
        .buttonStyle(.borderless)
        .accessibilityIdentifier("ai-base-url-paste")

        Button(String(localized: "恢复默认占位")) {
          restoreBaseURLPlaceholder()
        }
        .font(.workbenchMetadata)
        .buttonStyle(.borderless)
        .accessibilityIdentifier("ai-base-url-restore-default")
      }

      if let message = baseURLValidation.message {
        Label(message, systemImage: "exclamationmark.triangle")
          .font(.workbenchMetadata)
          .foregroundStyle(WorkbenchTheme.warning)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityElement(children: .combine)
          .accessibilityIdentifier("ai-base-url-validation")
      }

      if hasUnappliedBaseURL {
        HStack(spacing: WorkbenchSpacing.control) {
          Label("地址修改尚未应用", systemImage: "pencil.and.outline")
            .font(.workbenchMetadata)
            .foregroundStyle(WorkbenchTheme.warning)

          Spacer(minLength: WorkbenchSpacing.control)

          Button("取消修改") {
            baseURLDraft = baseURL.wrappedValue
          }
          .controlSize(.small)

          Button("应用地址") {
            applyBaseURLDraft()
          }
          .workbenchProminentActionStyle()
          .controlSize(.small)
        }
      }
    }
  }

  private var modelField: some View {
    VStack(alignment: .leading, spacing: 4) {
      ZStack(alignment: .trailing) {
        TextField(
          String(localized: "模型"),
          text: model
        )
        .padding(.trailing, WorkbenchSpacing.spacious)
        .accessibilityLabel(String(localized: "AI 模型"))
        .accessibilityValue(modelDisplayValue)
        .accessibilityIdentifier("settings-ai-model")

        if !model.wrappedValue.trimmedForPublishing.isEmpty {
          Button {
            model.wrappedValue = ""
          } label: {
            Image(systemName: "xmark.circle.fill")
              .foregroundStyle(.secondary)
          }
          .buttonStyle(.plain)
          .help(String(localized: "清空模型名称"))
          .accessibilityLabel(String(localized: "清空 AI 模型"))
          .accessibilityIdentifier("ai-model-clear")
        }
      }

      if !suggestedModels.isEmpty {
        HStack(spacing: 6) {
          Text("可用候选:")
            .font(.caption)
            .foregroundStyle(.secondary)
          ForEach(suggestedModels, id: \.self) { candidate in
            Button {
              model.wrappedValue = candidate
            } label: {
              Text(candidate)
                .font(.caption)
                .padding(.horizontal, WorkbenchSpacing.icon)
                .padding(.vertical, 2)
                .background(
                  model.wrappedValue == candidate
                    ? WorkbenchTheme.brand.opacity(0.15) : Color.primary.opacity(0.06),
                  in: Capsule()
                )
                .foregroundStyle(
                  model.wrappedValue == candidate ? WorkbenchTheme.brand : Color.primary)
            }
            .buttonStyle(.plain)
          }
        }

      }
      if !discoveredModels.isEmpty {
        HStack(spacing: 8) {
          Button {
            isSearchPopoverPresented = true
          } label: {
            HStack(spacing: 5) {
              Image(systemName: "magnifyingglass")
              Text("搜索与选择已拉取模型 (\(discoveredModels.count))")
              Image(systemName: "chevron.right").font(.workbenchMetadata)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
          }
          .buttonStyle(.borderless)
          .popover(isPresented: $isSearchPopoverPresented) {
            AIModelSearchPopoverView(
              models: discoveredModels,
              selectedModel: model.wrappedValue,
              onSelect: { selected in
                model.wrappedValue = selected
                isSearchPopoverPresented = false
              }
            )
          }

          Spacer()
        }
      }

      HStack(spacing: 10) {
        Button(String(localized: "拉取可用模型")) {
          fetchModelsFromAPI()
        }
        .font(.workbenchMetadata)
        .buttonStyle(.borderless)
        .disabled(isDiscoveringModels || !canDiscoverModels)
        .accessibilityLabel(String(localized: "拉取可用模型"))
        .accessibilityValue(
          isDiscoveringModels
            ? String(localized: "正在加载")
            : (hasUnappliedBaseURL
              ? String(localized: "请先应用地址")
              : String(localized: "可用"))
        )

        if isDiscoveringModels {
          ProgressView()
            .controlSize(.small)
            .accessibilityLabel(String(localized: "正在拉取可用模型"))
        }

        Button(String(localized: "粘贴剪贴板模型")) {
          pasteModelFromClipboard()
        }
        .font(.workbenchMetadata)
        .buttonStyle(.borderless)
        .accessibilityIdentifier("ai-model-paste")

        Button(String(localized: "恢复默认占位")) {
          restoreModelPlaceholder()
        }
        .font(.workbenchMetadata)
        .buttonStyle(.borderless)
        .accessibilityIdentifier("ai-model-restore-default")
      }

      if let modelDiscoveryAuthorizationMessage {
        Text(modelDiscoveryAuthorizationMessage)
          .font(.caption).foregroundStyle(.secondary)
      }
      if hasLoadedModels, !model.wrappedValue.isEmpty,
        !discoveredModels.contains(where: { $0.id == model.wrappedValue })
      {
        Text("当前模型未出现在本次返回列表中，原选择已保留。可检查账户权限或选择列表中的模型；列表缺失不代表模型已下线。")
          .font(.caption).foregroundStyle(WorkbenchTheme.warning)
          .accessibilityIdentifier("settings-ai-model-not-listed")
      }
      if let selected = discoveredModels.first(where: { $0.id == model.wrappedValue }) {
        AIModelMetadataView(model: selected)
      }
      if let discoveryErrorMessage {
        Text(discoveryErrorMessage)
          .font(.workbenchMetadata)
          .foregroundStyle(WorkbenchTheme.warning)
          .accessibilityLabel(String(localized: "模型发现失败"))
          .accessibilityValue(discoveryErrorMessage)
      }
      if modelDiscoveryAuthorizationMessage == nil, !model.wrappedValue.trimmedForPublishing.isEmpty
      {
        Button("继续验证连接", action: onContinueToVerification)
          .buttonStyle(.borderless)
          .accessibilityIdentifier("settings-ai-model-continue")
      }
    }
  }

  private var suggestedModels: [String] {
    Array(discoveredModels.prefix(4).map(\.id))
  }

  private func pasteBaseURLFromClipboard() {
    let value =
      NSPasteboard.general.string(forType: .URL)
      ?? NSPasteboard.general.string(forType: .string)
    guard let value, !value.trimmedForPublishing.isEmpty else { return }
    baseURLDraft = value.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func pasteModelFromClipboard() {
    guard let value = NSPasteboard.general.string(forType: .string) else { return }
    let normalized =
      value
      .components(separatedBy: .newlines)
      .joined(separator: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else { return }
    model.wrappedValue = normalized
  }

  private func restoreBaseURLPlaceholder() {
    baseURLDraft = presetBinding.wrappedValue.defaultBaseURL
  }

  private func restoreModelPlaceholder() {
    model.wrappedValue = presetBinding.wrappedValue.defaultModel
  }

  private func applyBaseURLDraft() {
    baseURL.wrappedValue = baseURLDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    baseURLDraft = baseURL.wrappedValue
  }

  private var canDiscoverModels: Bool {
    modelDiscoveryAuthorizationMessage == nil
      && !baseURL.wrappedValue.trimmedForPublishing.isEmpty
      && !hasUnappliedBaseURL
      && appliedBaseURLValidation.isUsable
  }

  private var baseURLValidation: AIConnectionEndpointValidation {
    AIConnectionEndpointValidation.validate(
      config: AIProviderConfig(
        preset: presetBinding.wrappedValue,
        baseURL: baseURLDraft,
        model: model.wrappedValue,
        requiresAPIKey: requiresAPIKeyBinding.wrappedValue
      )
    )
  }

  private var appliedBaseURLValidation: AIConnectionEndpointValidation {
    AIConnectionEndpointValidation.validate(
      config: AIProviderConfig(
        preset: presetBinding.wrappedValue,
        baseURL: baseURL.wrappedValue,
        model: model.wrappedValue,
        requiresAPIKey: requiresAPIKeyBinding.wrappedValue
      )
    )
  }

  private func fetchModelsFromAPI() {
    guard canDiscoverModels else {
      discoveryErrorMessage =
        hasUnappliedBaseURL
        ? String(localized: "请先应用 API 基础地址，再拉取模型。")
        : (appliedBaseURLValidation.message ?? String(localized: "AI 接口地址无效。"))
      return
    }
    modelDiscoveryTask?.cancel()
    let requestID = UUID()
    modelDiscoveryRequestID = requestID
    isDiscoveringModels = true
    discoveryErrorMessage = nil
    let config = AIProviderConfig(
      preset: presetBinding.wrappedValue,
      baseURL: baseURL.wrappedValue,
      model: model.wrappedValue,
      requiresAPIKey: requiresAPIKeyBinding.wrappedValue
    )
    let requestedConnectionID = connectionProfileID
    modelDiscoveryTask = Task {
      do {
        let models = try await discoverModels(requestedConnectionID, config)
        try Task.checkCancellation()
        await MainActor.run {
          guard self.modelDiscoveryRequestID == requestID,
            self.connectionProfileID == requestedConnectionID,
            self.baseURL.wrappedValue == config.baseURL,
            self.model.wrappedValue == config.model,
            self.presetBinding.wrappedValue == config.preset,
            self.requiresAPIKeyBinding.wrappedValue == config.requiresAPIKey
          else { return }
          self.discoveredModels = models
          self.hasLoadedModels = true
          self.isSearchPopoverPresented = !models.isEmpty
          self.isDiscoveringModels = false
          self.modelDiscoveryTask = nil
          if models.isEmpty {
            self.discoveryErrorMessage = String(localized: "未返回任何可用模型。")
          }
        }
      } catch is CancellationError {
        await MainActor.run {
          guard self.modelDiscoveryRequestID == requestID else { return }
          self.isDiscoveringModels = false
          self.modelDiscoveryTask = nil
        }
      } catch {
        await MainActor.run {
          guard self.modelDiscoveryRequestID == requestID else { return }
          self.isDiscoveringModels = false
          self.modelDiscoveryTask = nil
          self.discoveryErrorMessage = String(localized: "拉取模型列表失败：\(error.localizedDescription)")
        }
      }
    }
  }

  private func invalidateModelDiscovery() {
    modelDiscoveryRequestID = UUID()
    modelDiscoveryTask?.cancel()
    modelDiscoveryTask = nil
    isDiscoveringModels = false
    discoveredModels = []
    hasLoadedModels = false
    isSearchPopoverPresented = false
    discoveryErrorMessage = nil
  }
}
