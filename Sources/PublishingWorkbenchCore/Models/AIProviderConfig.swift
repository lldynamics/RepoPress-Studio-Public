import Foundation

public enum AIProviderPreset: String, Codable, CaseIterable, Identifiable, Sendable {
  case openAICompatible
  case deepSeek
  case openRouter
  case local
  case custom

  public static let deepSeekHighQualityModel = "deepseek-v4-pro"

  private static let legacyDeepSeekProRawValue = "deepSeekPro"

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .openAICompatible:
      return "OpenAI Compatible"
    case .deepSeek:
      return "DeepSeek"
    case .openRouter:
      return "OpenRouter"
    case .local:
      return "本地模型"
    case .custom:
      return "自定义"
    }
  }

  public var defaultBaseURL: String {
    switch self {
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
      throw DecodingError.dataCorruptedError(
        in: container,
        debugDescription: "Unsupported AI provider preset: \(rawValue)"
      )
    }
    self = preset
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

public enum AIProviderRequestPurpose: Sendable {
  case interactiveChat
  case utilityTask
  case connectionTest
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
      return "快速"
    case .standard:
      return "标准"
    case .highQuality:
      return "高质量"
    case .custom:
      return "自定义"
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
      return "普通对话"
    case .articleContextChat:
      return "文章上下文对话"
    case .textEditing:
      return "正文润色"
    case .metadataRepair:
      return "当前文章 metadata 修复"
    case .titleRewrite:
      return "标题 SEO 重写"
    case .articleStructure:
      return "文章结构检查"
    case .articleRelations:
      return "站内关联建议"
    case .imageAltCaption:
      return "图片 alt / caption"
    case .publishCopy:
      return "发布文案生成"
    case .prePublishReview:
      return "发布前审稿"
    case .batchMetadataRepair:
      return "批量旧文 metadata 修复"
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
      config.preset.defaultModel,
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
    let standardModel = defaultModel(for: config)
    switch grade {
    case .fast:
      return fastModel(for: config, fallback: standardModel)
    case .standard:
      return standardModel
    case .highQuality:
      return highQualityModel(for: config, fallback: standardModel)
    case .custom:
      let trimmed = currentModel.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? standardModel : trimmed
    }
  }

  private static func defaultModel(for config: AIProviderConfig) -> String {
    let configured = config.normalizedModel
    return configured.isEmpty ? config.preset.defaultModel : configured
  }

  private static func fastModel(for config: AIProviderConfig, fallback: String) -> String {
    switch config.preset {
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

  public init(
    preset: AIProviderPreset = .deepSeek,
    baseURL: String = AIProviderPreset.deepSeek.defaultBaseURL,
    model: String = AIProviderPreset.deepSeek.defaultModel,
    requiresAPIKey: Bool = true
  ) {
    self.preset = preset
    self.baseURL = baseURL
    self.model = model
    self.requiresAPIKey = requiresAPIKey
  }

  public var normalizedBaseURL: String {
    let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? preset.defaultBaseURL : trimmed
  }

  public var normalizedModel: String {
    let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? preset.defaultModel : trimmed
  }

  public var normalizedDisplayName: String {
    preset.displayName
  }

  public var normalizedRequestModel: String {
    requestModel(resolving: normalizedModel)
  }

  public var usesDeepSeekAPI: Bool {
    switch preset {
    case .deepSeek:
      return true
    case .openAICompatible, .openRouter, .local, .custom:
      let rawBaseURL = normalizedBaseURL.lowercased()
      if let host = URL(string: rawBaseURL)?.host?.lowercased() {
        return host == "api.deepseek.com"
      }
      return rawBaseURL.contains("api.deepseek.com")
    }
  }

  public var supportsImageInput: Bool {
    !usesDeepSeekAPI
  }

  public mutating func applyPresetDefaults() {
    baseURL = preset.defaultBaseURL
    model = preset.defaultModel
    requiresAPIKey = preset != .local
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
    case .utilityTask, .connectionTest:
      return AIProviderChatRequestOptions(
        temperature: nil,
        thinking: AIProviderThinkingOption(type: "disabled"),
        reasoningEffort: nil
      )
    }
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
      return "锦方 Zola"
    case .technicalNote:
      return "技术笔记"
    case .personalEssay:
      return "个人随笔"
    case .custom:
      return "自定义"
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
