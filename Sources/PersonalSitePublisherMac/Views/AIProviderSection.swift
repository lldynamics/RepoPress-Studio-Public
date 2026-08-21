import AppKit
import PublishingWorkbenchCore
import SwiftUI

enum AIConnectionKind: String, CaseIterable, Identifiable {
  case chatGPT
  case local
  case apiKey

  var id: String { rawValue }

  init(preset: AIProviderPreset) {
    switch preset {
    case .codexAppServer:
      self = .chatGPT
    case .local:
      self = .local
    case .openAICompatible, .deepSeek, .anthropic, .gemini, .siliconFlow, .moonshot, .zhipu, .openRouter, .custom:
      self = .apiKey
    }
  }

  var title: String {
    switch self {
    case .chatGPT: return String(localized: "ChatGPT 登录")
    case .local: return String(localized: "本地模型")
    case .apiKey: return "API Key"
    }
  }

  var systemImage: String {
    switch self {
    case .chatGPT: return "person.crop.circle.badge.checkmark"
    case .local: return "desktopcomputer"
    case .apiKey: return "key.fill"
    }
  }
}

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
  @State private var baseURLDraft: String
  @State private var discoveredModels: [AIModelDescriptor] = []
  @State private var isDiscoveringModels = false
  @State private var discoveryErrorMessage: String?
  @State private var modelDiscoveryTask: Task<Void, Never>?
  @State private var modelDiscoveryRequestID = UUID()
  @State private var isSearchPopoverPresented = false

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
    discoverModels: @escaping (UUID, AIProviderConfig) async throws -> [AIModelDescriptor]
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
        baseURLField

        modelField

        Toggle(String(localized: "需要 API 密钥"), isOn: requiresAPIKeyBinding)
          .accessibilityLabel(String(localized: "AI 需要 API Key"))
          .accessibilityValue(requiresAPIKeyDisplayValue)
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
    }
    .onChange(of: presetBinding.wrappedValue) { _, _ in
      invalidateModelDiscovery()
    }
    .onChange(of: connectionProfileID) { _, _ in
      invalidateModelDiscovery()
    }
    .onDisappear {
      invalidateModelDiscovery()
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
        .padding(.trailing, 24)
        .textContentType(.URL)
        .accessibilityLabel(String(localized: "AI Base URL"))
        .accessibilityValue(baseURLDraft.nilIfEmpty ?? String(localized: "未填写"))

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
        .padding(.trailing, 24)
        .accessibilityLabel(String(localized: "AI 模型"))
        .accessibilityValue(modelDisplayValue)

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

      HStack(spacing: 6) {
        Text("常用候选:")
          .font(.caption)
          .foregroundStyle(.secondary)
        ForEach(suggestedModels, id: \.self) { candidate in
          Button {
            model.wrappedValue = candidate
          } label: {
            Text(candidate)
              .font(.caption)
              .padding(.horizontal, 6)
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
            .foregroundStyle(WorkbenchTheme.brand)
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

      if let discoveryErrorMessage {
        Text(discoveryErrorMessage)
          .font(.workbenchMetadata)
          .foregroundStyle(WorkbenchTheme.warning)
          .accessibilityLabel(String(localized: "模型发现失败"))
          .accessibilityValue(discoveryErrorMessage)
      }
    }
  }

  private var suggestedModels: [String] {
    switch presetBinding.wrappedValue {
    case .codexAppServer:
      return []
    case .openAICompatible:
      return ["gpt-4o", "gpt-4o-mini", "o3-mini"]
    case .deepSeek:
      return ["deepseek-chat", "deepseek-reasoner"]
    case .anthropic:
      return ["claude-sonnet-4-6", "claude-opus-4-6", "claude-haiku-4-5"]
    case .gemini:
      return ["gemini-2.0-flash", "gemini-1.5-pro", "gemini-1.5-flash"]
    case .siliconFlow:
      return ["deepseek-ai/DeepSeek-V3", "deepseek-ai/DeepSeek-R1", "Qwen/Qwen2.5-72B-Instruct"]
    case .moonshot:
      return ["moonshot-v1-auto", "moonshot-v1-8k", "moonshot-v1-32k"]
    case .zhipu:
      return ["glm-4-flash", "glm-4-plus", "glm-4-air"]
    case .openRouter:
      return ["anthropic/claude-sonnet-4-6", "google/gemini-2.0-flash-001", "deepseek/deepseek-r1"]
    case .local:
      return ["llama3.2", "qwen2.5-coder", "deepseek-r1"]
    case .custom:
      return ["gpt-4o", "deepseek-chat", "claude-sonnet-4-6"]
    }
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

  private func restorePresetDefaults() {
    let preset = presetBinding.wrappedValue
    baseURLDraft = preset.defaultBaseURL
    baseURL.wrappedValue = preset.defaultBaseURL
    model.wrappedValue = preset.defaultModel
    requiresAPIKeyBinding.wrappedValue = (preset != .local && preset != .codexAppServer)
  }

  private func applyBaseURLDraft() {
    baseURL.wrappedValue = baseURLDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    baseURLDraft = baseURL.wrappedValue
  }

  private var canDiscoverModels: Bool {
    !baseURL.wrappedValue.trimmedForPublishing.isEmpty && !hasUnappliedBaseURL
  }

  private func fetchModelsFromAPI() {
    guard canDiscoverModels else {
      discoveryErrorMessage = String(localized: "请先应用 API 基础地址，再拉取模型。")
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
    modelDiscoveryTask = Task {
      do {
        let models = try await discoverModels(connectionProfileID, config)
        try Task.checkCancellation()
        await MainActor.run {
          guard self.modelDiscoveryRequestID == requestID else { return }
          self.discoveredModels = models
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
    discoveryErrorMessage = nil
  }
}

struct AIModelSearchPopoverView: View {
  let models: [AIModelDescriptor]
  let selectedModel: String
  let onSelect: (String) -> Void
  @State private var searchText = ""

  var filteredModels: [AIModelDescriptor] {
    let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
      return models
    }
    return models.filter {
      $0.id.localizedCaseInsensitiveContains(trimmed)
        || $0.name.localizedCaseInsensitiveContains(trimmed)
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 6) {
        Image(systemName: "magnifyingglass")
          .foregroundStyle(.secondary)
        TextField(String(localized: "搜索模型 (如 r1, sonnet, gemini, flash...)"), text: $searchText)
          .textFieldStyle(.plain)
          .font(.body)
          .accessibilityLabel(
            String(localized: "搜索模型 (如 r1, sonnet, gemini, flash...)")
          )
        if !searchText.isEmpty {
          Button {
            searchText = ""
          } label: {
            Image(systemName: "xmark.circle.fill")
              .foregroundStyle(.secondary)
          }
          .buttonStyle(.plain)
        }
      }
      .padding(8)
      .background(Color.primary.opacity(0.04))

      Divider()

      if filteredModels.isEmpty {
        VStack(spacing: 6) {
          Spacer()
          Image(systemName: "questionmark.folder")
            .font(.title2)
            .foregroundStyle(.secondary)
          Text("未找到包含 \"\(searchText)\" 的模型")
            .font(.caption)
            .foregroundStyle(.secondary)
          Spacer()
        }
        .frame(minHeight: 140)
      } else {
        ScrollView {
          LazyVStack(spacing: 2) {
            ForEach(filteredModels) { descriptor in
              Button {
                onSelect(descriptor.id)
              } label: {
                HStack(spacing: 8) {
                  VStack(alignment: .leading, spacing: 2) {
                    Text(descriptor.name)
                      .font(.callout.monospaced())
                      .foregroundStyle(Color.primary)
                    if descriptor.id != descriptor.name {
                      Text(descriptor.id)
                        .font(.workbenchMetadata.monospaced())
                        .foregroundStyle(.secondary)
                    }
                  }

                  Spacer()

                  if descriptor.isReasoning {
                    Text("深度思考")
                      .font(.workbenchMetadata.weight(.medium))
                      .padding(.horizontal, 5)
                      .padding(.vertical, 2)
                      .background(Color.purple.opacity(0.15), in: Capsule())
                      .foregroundStyle(.purple)
                  }

                  if descriptor.isVision {
                    Text("多模态")
                      .font(.workbenchMetadata.weight(.medium))
                      .padding(.horizontal, 5)
                      .padding(.vertical, 2)
                      .background(Color.blue.opacity(0.15), in: Capsule())
                      .foregroundStyle(.blue)
                  }

                  if descriptor.id == selectedModel {
                    Image(systemName: "checkmark")
                      .font(.caption.weight(.bold))
                      .foregroundStyle(WorkbenchTheme.brand)
                  }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
                .background(
                  descriptor.id == selectedModel
                    ? WorkbenchTheme.brand.opacity(0.08)
                    : Color.clear,
                  in: RoundedRectangle(cornerRadius: 4)
                )
              }
              .buttonStyle(.plain)
            }
          }
          .padding(6)
        }
        .frame(minHeight: 200, maxHeight: 320)
      }

      Divider()

      HStack {
        Text("共 \(models.count) 个可用模型")
          .font(.workbenchMetadata)
          .foregroundStyle(.secondary)
        Spacer()
        if !searchText.isEmpty {
          Text("已筛选出 \(filteredModels.count) 个")
            .font(.workbenchMetadata)
            .foregroundStyle(WorkbenchTheme.brand)
        }
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
    }
    .frame(width: 360)
  }
}
