import Foundation

public enum AIProviderPreset: String, Codable, CaseIterable, Identifiable, Sendable {
  case codexAppServer
  case openAICompatible
  case deepSeek
  case openRouter
  case local
  case custom

  public static let deepSeekHighQualityModel = "deepseek-v4-pro"
  public static let codexDefaultModel = "codex-default"

  private static let legacyDeepSeekProRawValue = "deepSeekPro"

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .codexAppServer:
      return CoreL10n.text("Codex 套餐")
    case .openAICompatible:
      return CoreL10n.text("OpenAI 兼容")
    case .deepSeek:
      return "DeepSeek"
    case .openRouter:
      return "OpenRouter"
    case .local:
      return CoreL10n.text("本地模型")
    case .custom:
      return CoreL10n.text("自定义")
    }
  }

  public var defaultBaseURL: String {
    switch self {
    case .codexAppServer:
      // This loopback-looking value is an internal transport identity only.
      // Requests for this preset are routed through `codex app-server` stdio
      // and never posted to this URL.
      return "http://127.0.0.1/__repopress_codex_app_server__"
    case .openAICompatible:
      return "https://api.openai.com/v1"
    case .deepSeek:
      return "https://api.deepseek.com"
    case .openRouter:
      return "https://openrouter.ai/api/v1"
    case .local:
      return "http://127.0.0.1:11434/v1"
    case .custom:
      return ""
    }
  }

  public var defaultModel: String {
    switch self {
    case .codexAppServer:
      // The App Server omits the model override for this sentinel so Codex can
      // choose the account's current default model.
      return Self.codexDefaultModel
    case .openAICompatible:
      return "gpt-4.1-mini"
    case .deepSeek:
      return "deepseek-v4-flash"
    case .openRouter, .custom:
      return ""
    case .local:
      return "llama3.1"
    }
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    let rawValue = try container.decode(String.self)
    if rawValue == Self.legacyDeepSeekProRawValue {
      self = .deepSeek
      return
    }
    guard let preset = Self(rawValue: rawValue) else {
      self = .custom
      return
    }
    self = preset
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

public enum AIProviderRequestPurpose: String, Codable, Equatable, Hashable, Sendable {
  case interactiveChat = "interactive_chat"
  case utilityTask = "utility_task"
  case connectionTest = "connection_test"
  /// Used only by the capability probe service to intentionally test optional
  /// protocol fields before normal runtime requests are allowed to use them.
  case capabilityProbe = "capability_probe"
}

public struct AIProviderThinkingOption: Codable, Hashable, Sendable {
  public var type: String

  public init(type: String) {
    self.type = type
  }
}

public struct AIProviderChatRequestOptions: Hashable, Sendable {
  public var temperature: Double?
  public var thinking: AIProviderThinkingOption?
  public var reasoningEffort: String?

  public init(
    temperature: Double?,
    thinking: AIProviderThinkingOption?,
    reasoningEffort: String?
  ) {
    self.temperature = temperature
    self.thinking = thinking
    self.reasoningEffort = reasoningEffort
  }
}

public enum AIChatModelGrade: String, CaseIterable, Codable, Identifiable, Sendable {
  case fast
  case standard
  case highQuality
  case custom

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .fast:
      return CoreL10n.text("快速")
    case .standard:
      return CoreL10n.text("标准")
    case .highQuality:
      return CoreL10n.text("高质量")
    case .custom:
      return CoreL10n.text("自定义")
    }
  }
}

public enum AIChatReasoningLevel: String, CaseIterable, Codable, Identifiable, Sendable {
  case quick
  case standard
  case deep

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .quick:
      return CoreL10n.text("快速")
    case .standard:
      return CoreL10n.text("标准")
    case .deep:
      return CoreL10n.text("深度")
    }
  }

  public func requestOptions(for config: AIProviderConfig) -> AIProviderChatRequestOptions? {
    guard config.usesDeepSeekAPI else { return nil }
    switch self {
    case .quick:
      return AIProviderChatRequestOptions(
        temperature: nil,
        thinking: AIProviderThinkingOption(type: "disabled"),
        reasoningEffort: nil
      )
    case .standard:
      return AIProviderChatRequestOptions(
        temperature: nil,
        thinking: AIProviderThinkingOption(type: "enabled"),
        reasoningEffort: nil
      )
    case .deep:
      return AIProviderChatRequestOptions(
        temperature: nil,
        thinking: AIProviderThinkingOption(type: "enabled"),
        reasoningEffort: "high"
      )
    }
  }
}

public enum AIModelTaskKind: String, CaseIterable, Codable, Identifiable, Sendable {
  case chat
  case articleContextChat
  case textEditing
  case metadataRepair
  case titleRewrite
  case articleStructure
  case articleRelations
  case imageAltCaption
  case publishCopy
  case prePublishReview
  case batchMetadataRepair

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .chat:
      return CoreL10n.text("普通对话")
    case .articleContextChat:
      return CoreL10n.text("文章上下文对话")
    case .textEditing:
      return CoreL10n.text("正文润色")
    case .metadataRepair:
      return CoreL10n.text("当前文章 metadata 修复")
    case .titleRewrite:
      return CoreL10n.text("标题 SEO 重写")
    case .articleStructure:
      return CoreL10n.text("文章结构检查")
    case .articleRelations:
      return CoreL10n.text("站内关联建议")
    case .imageAltCaption:
      return CoreL10n.text("图片 alt / caption")
    case .publishCopy:
      return CoreL10n.text("发布文案生成")
    case .prePublishReview:
      return CoreL10n.text("发布前审稿")
    case .batchMetadataRepair:
      return CoreL10n.text("批量旧文 metadata 修复")
    }
  }

  public var preferredGrade: AIChatModelGrade {
    switch self {
    case .chat, .articleContextChat, .textEditing, .metadataRepair, .titleRewrite,
      .articleStructure, .articleRelations, .imageAltCaption, .publishCopy:
      return .standard
    case .prePublishReview:
      return .highQuality
    case .batchMetadataRepair:
      return .fast
    }
  }
}

public enum AIChatModelCatalog {
  public static func modelCandidates(
    activeModel: String,
    config: AIProviderConfig
  ) -> [String] {
    uniqueModels([
      activeModel,
      model(for: .fast, config: config, currentModel: activeModel),
      model(for: .standard, config: config, currentModel: activeModel),
      model(for: .highQuality, config: config, currentModel: activeModel),
      config.normalizedModel,
    ])
  }

  public static func config(
    for task: AIModelTaskKind,
    baseConfig: AIProviderConfig,
    currentModel: String? = nil
  ) -> AIProviderConfig {
    var config = baseConfig
    config.model = model(
      for: task.preferredGrade,
      config: baseConfig,
      currentModel: currentModel ?? baseConfig.normalizedModel
    )
    return config
  }

  public static func model(
    for grade: AIChatModelGrade,
    config: AIProviderConfig,
    currentModel: String
  ) -> String {
    let trimmedCurrentModel = currentModel.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !config.normalizedModel.isEmpty || !trimmedCurrentModel.isEmpty else {
      return ""
    }
    let standardModel = defaultModel(for: config)
    switch grade {
    case .fast:
      return fastModel(for: config, fallback: standardModel)
    case .standard:
      return standardModel
    case .highQuality:
      return highQualityModel(for: config, fallback: standardModel)
    case .custom:
      return trimmedCurrentModel.isEmpty ? standardModel : trimmedCurrentModel
    }
  }

  private static func defaultModel(for config: AIProviderConfig) -> String {
    config.normalizedModel
  }

  private static func fastModel(for config: AIProviderConfig, fallback: String) -> String {
    switch config.preset {
    case .codexAppServer:
      return fallback
    case .deepSeek:
      return AIProviderPreset.deepSeek.defaultModel
    case .openAICompatible:
      return AIProviderPreset.openAICompatible.defaultModel
    case .local:
      return AIProviderPreset.local.defaultModel
    case .openRouter, .custom:
      return fallback
    }
  }

  private static func highQualityModel(for config: AIProviderConfig, fallback: String) -> String {
    switch config.preset {
    case .codexAppServer:
      return fallback
    case .deepSeek:
      return AIProviderPreset.deepSeekHighQualityModel
    case .openAICompatible:
      return "gpt-4.1"
    case .openRouter, .local, .custom:
      return fallback
    }
  }

  private static func uniqueModels(_ values: [String]) -> [String] {
    var seen: Set<String> = []
    var result: [String] = []
    for value in values {
      let model = value.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !model.isEmpty, !seen.contains(model) else {
        continue
      }
      seen.insert(model)
      result.append(model)
    }
    return result
  }
}

public struct AIChatModelSelectionPresentation: Equatable, Sendable {
  public var activeModel: String
  public var defaultModel: String
  public var modelCandidates: [String]
  public var canEditCustomModel: Bool

  public init(
    activeModel: String,
    defaultModel: String,
    modelCandidates: [String],
    canEditCustomModel: Bool
  ) {
    self.activeModel = activeModel
    self.defaultModel = defaultModel
    self.modelCandidates = modelCandidates
    self.canEditCustomModel = canEditCustomModel
  }
}

public enum AIChatModelSelectionPresentationService {
  public static func presentation(
    grade: AIChatModelGrade,
    selectedModel: String,
    config: AIProviderConfig
  ) -> AIChatModelSelectionPresentation {
    let activeModel = AIChatModelCatalog.model(
      for: grade,
      config: config,
      currentModel: grade == .custom ? selectedModel : config.normalizedModel
    )
    let defaultModel = AIChatModelCatalog.model(
      for: .standard,
      config: config,
      currentModel: config.normalizedModel
    )
    return AIChatModelSelectionPresentation(
      activeModel: activeModel,
      defaultModel: defaultModel,
      modelCandidates: AIChatModelCatalog.modelCandidates(
        activeModel: activeModel,
        config: config
      ),
      canEditCustomModel: grade == .custom
    )
  }
}

public struct AIProviderConfig: Codable, Hashable, Sendable {
  public var preset: AIProviderPreset
  public var baseURL: String
  public var model: String
  public var requiresAPIKey: Bool
  public var advancedSettings: AIProviderAdvancedSettings?
  /// Endpoint/model-bound probe evidence. This contains no credential or
  /// response body and is ignored whenever its cache key no longer matches
  /// this config.
  public var capabilityProbeEvidence:
    [AIProviderCapabilityProbeKind: AIProviderCapabilityProbeEvidence]?

  public init(
    preset: AIProviderPreset = .custom,
    baseURL: String = "",
    model: String = "",
    requiresAPIKey: Bool = true,
    advancedSettings: AIProviderAdvancedSettings? = nil,
    capabilityProbeEvidence: [AIProviderCapabilityProbeKind: AIProviderCapabilityProbeEvidence]? =
      nil
  ) {
    self.preset = preset
    self.baseURL = baseURL
    self.model = model
    self.requiresAPIKey = requiresAPIKey
    self.advancedSettings = advancedSettings
    self.capabilityProbeEvidence = capabilityProbeEvidence
  }

  public var resolvedAdvancedSettings: AIProviderAdvancedSettings {
    advancedSettings ?? AIProviderAdvancedSettings()
  }

  public var normalizedBaseURL: String {
    baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  public var normalizedModel: String {
    model.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Stable identity for capability evidence. Only scheme, host, port and
  /// path participate; user info, query, fragment and any secret-like URL
  /// material are intentionally discarded.
  public var capabilityEndpointIdentity: String {
    guard let components = URLComponents(string: normalizedBaseURL),
      let scheme = components.scheme?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
      let rawHost = components.host?.trimmingCharacters(in: .whitespacesAndNewlines),
      !scheme.isEmpty,
      !rawHost.isEmpty
    else {
      return normalizedBaseURL.lowercased()
    }

    let host = rawHost.lowercased()
    let renderedHost =
      host.contains(":") && !host.hasPrefix("[")
      ? "[\(host)]"
      : host
    let port =
      components.port
      ?? ((scheme == "https" || scheme == "wss")
        ? 443 : (scheme == "http" || scheme == "ws" ? 80 : nil))
    let portPart = port.map { ":\($0)" } ?? ""
    let path = normalizedCapabilityPath(components.path)
    return "\(scheme)://\(renderedHost)\(portPart)\(path)"
  }

  public var capabilityCacheKey: AIProviderCapabilityCacheKey {
    AIProviderCapabilityCacheKey(config: self)
  }

  public var normalizedDisplayName: String {
    preset.displayName
  }

  public var normalizedRequestModel: String {
    requestModel(resolving: normalizedModel)
  }

  public var usesCodexAppServer: Bool {
    preset == .codexAppServer
  }

  public var dataSharingDestination: String {
    if usesCodexAppServer {
      return CoreL10n.text("Codex / ChatGPT")
    }
    let resolvedBaseURL = normalizedBaseURL
    if resolvedBaseURL.isEmpty {
      return ""
    }
    guard let url = URL(string: resolvedBaseURL),
      let host = url.host?.lowercased()
    else {
      return resolvedBaseURL
    }
    if let port = url.port {
      return "\(host):\(port)"
    }
    return host
  }

  public var isLocalEndpoint: Bool {
    // App Server runs locally but sends the approved prompt to the user's
    // managed ChatGPT/Codex account, so it must retain the remote-data gate.
    guard !usesCodexAppServer else { return false }
    guard let host = URL(string: normalizedBaseURL)?.host?.lowercased() else {
      return false
    }
    return host == "localhost"
      || host == "127.0.0.1"
      || host == "::1"
      || host.hasSuffix(".localhost")
  }

  public var dataSharingConsentIdentifier: String {
    if usesCodexAppServer {
      return "codexAppServer|chatgpt"
    }
    guard let components = URLComponents(string: normalizedBaseURL),
      let scheme = components.scheme?.lowercased(),
      let host = components.host?.lowercased()
    else {
      return "\(preset.rawValue)|\(normalizedBaseURL.lowercased())"
    }
    let port = components.port.map(String.init) ?? ""
    let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    return "\(preset.rawValue)|\(scheme)|\(host)|\(port)|\(path)"
  }

  public var usesDeepSeekAPI: Bool {
    switch preset {
    case .deepSeek:
      return true
    case .codexAppServer, .openAICompatible, .openRouter, .local, .custom:
      let rawBaseURL = normalizedBaseURL.lowercased()
      if let host = URL(string: rawBaseURL)?.host?.lowercased() {
        return host == "api.deepseek.com"
      }
      return rawBaseURL.contains("api.deepseek.com")
    }
  }

  public var supportsImageInput: Bool {
    capabilitySupport(for: .visionInput) == .supported
  }

  public mutating func applyPresetDefaults() {
    baseURL = preset.defaultBaseURL
    model = preset.defaultModel
    requiresAPIKey = preset != .local && preset != .codexAppServer
  }

  public var chatCompletionsURL: URL? {
    let trimmed = normalizedBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    guard let baseURL = URL(string: trimmed), baseURL.scheme != nil, baseURL.host != nil else {
      return nil
    }
    guard !requiresAPIKey || baseURL.scheme?.lowercased() == "https" else {
      return nil
    }
    return URL(string: trimmed + "/chat/completions")
  }

  public func requestModel(resolving candidate: String? = nil) -> String {
    let model = (candidate ?? normalizedModel)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard usesDeepSeekAPI else {
      return model
    }

    switch model {
    case "deepseek-chat":
      return AIProviderPreset.deepSeek.defaultModel
    case "deepseek-reasoner":
      return AIProviderPreset.deepSeekHighQualityModel
    default:
      return model
    }
  }

  public func chatRequestOptions(
    temperature: Double?,
    purpose: AIProviderRequestPurpose
  ) -> AIProviderChatRequestOptions {
    guard usesDeepSeekAPI else {
      return AIProviderChatRequestOptions(
        temperature: temperature,
        thinking: nil,
        reasoningEffort: nil
      )
    }

    switch purpose {
    case .interactiveChat:
      return AIProviderChatRequestOptions(
        temperature: nil,
        thinking: AIProviderThinkingOption(type: "enabled"),
        reasoningEffort: "high"
      )
    case .utilityTask, .connectionTest, .capabilityProbe:
      return AIProviderChatRequestOptions(
        temperature: nil,
        thinking: AIProviderThinkingOption(type: "disabled"),
        reasoningEffort: nil
      )
    }
  }

  public func capabilityEvidence(
    for capability: AIProviderCapability,
    at date: Date = Date()
  ) -> AIProviderCapabilityProbeEvidence? {
    guard let kind = AIProviderCapabilityProbeKind(capability: capability) else {
      return nil
    }
    return currentCapabilityEvidence(for: kind, at: date)
  }

  public func capabilitySupport(
    for capability: AIProviderCapability,
    at date: Date = Date()
  ) -> AIProviderCapabilitySupport {
    guard let kind = AIProviderCapabilityProbeKind(capability: capability) else {
      return staticCapabilitySupport(for: capability)
    }
    return capabilitySupport(
      for: kind,
      staticSupport: staticCapabilitySupport(for: capability),
      at: date
    )
  }

  public func capabilitySupport(
    for capability: AIProviderProtocolCapability,
    at date: Date = Date()
  ) -> AIProviderCapabilitySupport {
    let kind: AIProviderCapabilityProbeKind =
      capability == .toolCalling
      ? .toolCalling
      : .structuredOutput
    return capabilitySupport(
      for: kind,
      staticSupport: staticCapabilitySupport(for: capability),
      at: date
    )
  }

  public func capabilityEvidence(
    for capability: AIProviderProtocolCapability,
    at date: Date = Date()
  ) -> AIProviderCapabilityProbeEvidence? {
    let kind: AIProviderCapabilityProbeKind =
      capability == .toolCalling
      ? .toolCalling
      : .structuredOutput
    return currentCapabilityEvidence(for: kind, at: date)
  }

  public func capabilityEvidenceState(
    for capability: AIProviderCapability,
    at date: Date = Date()
  ) -> AIProviderCapabilityEvidenceState {
    guard let kind = AIProviderCapabilityProbeKind(capability: capability) else {
      return staticCapabilitySupport(for: capability) == .unknown ? .unknown : .staticInference
    }
    return capabilityEvidenceState(
      for: kind, staticSupport: staticCapabilitySupport(for: capability), at: date)
  }

  public func capabilityEvidenceState(
    for capability: AIProviderProtocolCapability,
    at date: Date = Date()
  ) -> AIProviderCapabilityEvidenceState {
    let kind: AIProviderCapabilityProbeKind =
      capability == .toolCalling
      ? .toolCalling
      : .structuredOutput
    return capabilityEvidenceState(
      for: kind,
      staticSupport: staticCapabilitySupport(for: capability),
      at: date
    )
  }

  private func normalizedCapabilityPath(_ value: String) -> String {
    let trimmed = value.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    return trimmed.isEmpty ? "/" : "/\(trimmed)"
  }

  private func currentCapabilityEvidence(
    for kind: AIProviderCapabilityProbeKind,
    at date: Date
  ) -> AIProviderCapabilityProbeEvidence? {
    guard let evidence = capabilityProbeEvidence?[kind],
      evidence.key == AIProviderCapabilityCacheKey(config: self),
      evidence.key.probeSchemaVersion == AIProviderCapabilityCacheKey.currentProbeSchemaVersion,
      date >= evidence.observedAt,
      date < evidence.expiresAt
    else {
      return nil
    }
    return evidence
  }

  private func capabilityEvidenceState(
    for kind: AIProviderCapabilityProbeKind,
    staticSupport: AIProviderCapabilitySupport,
    at date: Date
  ) -> AIProviderCapabilityEvidenceState {
    guard let evidence = capabilityProbeEvidence?[kind],
      evidence.key == AIProviderCapabilityCacheKey(config: self)
    else {
      return staticSupport == .unknown ? .unknown : .staticInference
    }
    return evidence.isCurrent(at: date) ? .probed : .expired
  }

  private func capabilitySupport(
    for kind: AIProviderCapabilityProbeKind,
    staticSupport: AIProviderCapabilitySupport,
    at date: Date
  ) -> AIProviderCapabilitySupport {
    guard let evidence = capabilityProbeEvidence?[kind] else {
      return staticSupport
    }
    guard evidence.key == AIProviderCapabilityCacheKey(config: self) else {
      // Evidence from a different endpoint/model/schema is not reusable. A
      // trusted preset may still use its static contract; custom endpoints
      // remain unknown through their static support value.
      return staticSupport
    }
    return evidence.isCurrent(at: date) ? evidence.support : .unknown
  }

  private func staticCapabilitySupport(
    for capability: AIProviderCapability
  ) -> AIProviderCapabilitySupport {
    switch capability {
    case .chat, .streamingResponse:
      guard chatCompletionsURL != nil, !normalizedModel.isEmpty else {
        return .unknown
      }
      return preset.capabilitySupport(for: capability)

    case .visionInput:
      if usesDeepSeekAPI {
        return .unsupported
      }
      return preset.capabilitySupport(for: capability)

    case .reasoningControl:
      if usesDeepSeekAPI {
        return .supported
      }
      return preset.capabilitySupport(for: capability)

    case .localService:
      if isLocalEndpoint {
        return .supported
      }
      if hasResolvedRemoteEndpoint {
        return .unsupported
      }
      return preset.capabilitySupport(for: capability)

    case .modelDiscovery:
      if preset == .local {
        if isLocalEndpoint {
          return .supported
        }
        return hasResolvedRemoteEndpoint ? .unsupported : .unknown
      }
      return preset.capabilitySupport(for: capability)
    }
  }

  private func staticCapabilitySupport(
    for capability: AIProviderProtocolCapability
  ) -> AIProviderCapabilitySupport {
    guard chatCompletionsURL != nil, !normalizedModel.isEmpty else {
      return .unknown
    }
    guard preset != .custom, preset != .local else {
      return .unknown
    }
    if capability == .toolCalling,
      preset == .deepSeek,
      !hasStaticallyKnownDeepSeekToolCallingModel
    {
      return .unknown
    }
    return preset.capabilitySupport(for: capability)
  }

  private var hasResolvedRemoteEndpoint: Bool {
    guard let host = URL(string: normalizedBaseURL)?.host, !host.isEmpty else {
      return false
    }
    return !isLocalEndpoint
  }

  private var hasStaticallyKnownDeepSeekToolCallingModel: Bool {
    [
      AIProviderPreset.deepSeek.defaultModel,
      AIProviderPreset.deepSeekHighQualityModel,
      "deepseek-chat",
      "deepseek-reasoner",
    ].contains(normalizedModel)
  }
}

public enum AIWritingStylePreset: String, Codable, CaseIterable, Identifiable, Sendable {
  case jinfangZola
  case technicalNote
  case personalEssay
  case custom

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .jinfangZola:
      return CoreL10n.text("锦方 Zola")
    case .technicalNote:
      return CoreL10n.text("技术笔记")
    case .personalEssay:
      return CoreL10n.text("个人随笔")
    case .custom:
      return CoreL10n.text("自定义")
    }
  }

  fileprivate var defaultTone: String {
    switch self {
    case .jinfangZola:
      return "克制、实用、直接，避免营销口吻和夸张形容。"
    case .technicalNote:
      return "准确、结构清晰，优先说明背景、做法、限制和结论。"
    case .personalEssay:
      return "自然、真诚，有个人观察，但不写成宣传文案。"
    case .custom:
      return ""
    }
  }

  fileprivate var defaultAudience: String {
    switch self {
    case .jinfangZola:
      return "关注个人网站、静态博客、工程工具和内容维护的读者。"
    case .technicalNote:
      return "需要复现步骤、判断取舍或理解实现细节的技术读者。"
    case .personalEssay:
      return "熟悉作者长期主题、希望快速了解观点和背景的个人网站读者。"
    case .custom:
      return ""
    }
  }

  fileprivate var defaultSummaryGuidance: String {
    switch self {
    case .jinfangZola:
      return "生成 80 到 140 字中文摘要，先说文章解决的问题，再说主要结论。"
    case .technicalNote:
      return "生成 60 到 120 字中文摘要，突出技术对象、关键步骤和适用边界。"
    case .personalEssay:
      return "生成 60 到 140 字中文摘要，保留个人视角，避免空泛鸡汤。"
    case .custom:
      return ""
    }
  }

  fileprivate var defaultTagGuidance: String {
    switch self {
    case .jinfangZola:
      return "优先提取工具、框架、站点类型和维护场景，3 到 6 个短标签，不要泛泛使用“随笔”。"
    case .technicalNote:
      return "优先使用技术栈、问题域和具体工具名，避免重复 title 里的长词组。"
    case .personalEssay:
      return "优先使用主题、场景和长期栏目标签，数量少而稳定。"
    case .custom:
      return ""
    }
  }

  fileprivate var defaultSEOGuidance: String {
    switch self {
    case .jinfangZola:
      return "重点检查 description、tags/categories、og_preview_img、标题清晰度和旧文章维护问题。"
    case .technicalNote:
      return "重点检查标题是否包含技术对象、摘要是否可搜索、代码块和图片说明是否完整。"
    case .personalEssay:
      return "重点检查分享卡片是否清楚、摘要是否有具体主题、标签是否和站点长期分类一致。"
    case .custom:
      return ""
    }
  }
}

public struct AIWritingStyleConfig: Codable, Hashable, Sendable {
  public var preset: AIWritingStylePreset
  public var tone: String
  public var audience: String
  public var summaryGuidance: String
  public var tagGuidance: String
  public var seoGuidance: String

  public init(
    preset: AIWritingStylePreset = .jinfangZola,
    tone: String? = nil,
    audience: String? = nil,
    summaryGuidance: String? = nil,
    tagGuidance: String? = nil,
    seoGuidance: String? = nil
  ) {
    self.preset = preset
    self.tone = tone ?? preset.defaultTone
    self.audience = audience ?? preset.defaultAudience
    self.summaryGuidance = summaryGuidance ?? preset.defaultSummaryGuidance
    self.tagGuidance = tagGuidance ?? preset.defaultTagGuidance
    self.seoGuidance = seoGuidance ?? preset.defaultSEOGuidance
  }

  public static let `default` = AIWritingStyleConfig()

  public mutating func applyPreset(_ preset: AIWritingStylePreset) {
    self.preset = preset
    guard preset != .custom else {
      return
    }

    tone = preset.defaultTone
    audience = preset.defaultAudience
    summaryGuidance = preset.defaultSummaryGuidance
    tagGuidance = preset.defaultTagGuidance
    seoGuidance = preset.defaultSEOGuidance
  }

  public mutating func normalizeWhitespace() {
    tone = normalized(tone)
    audience = normalized(audience)
    summaryGuidance = normalized(summaryGuidance)
    tagGuidance = normalized(tagGuidance)
    seoGuidance = normalized(seoGuidance)
  }

  public var promptInstructions: String {
    [
      ("语气", normalized(tone)),
      ("目标读者", normalized(audience)),
      ("摘要规则", normalized(summaryGuidance)),
      ("标签规则", normalized(tagGuidance)),
      ("SEO 检查重点", normalized(seoGuidance)),
    ]
    .filter { !$0.1.isEmpty }
    .map { "- \($0.0)：\($0.1)" }
    .joined(separator: "\n")
  }

  private func normalized(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
