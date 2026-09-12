import Foundation

public enum AIModelMetadataSource: String, Codable, Hashable, Sendable {
  case heuristic
  case provider
}

public struct AIModelDescriptor: Codable, Hashable, Identifiable, Sendable {
  public var id: String
  public var name: String
  public var isReasoning: Bool
  public var isVision: Bool
  public var isChat: Bool
  public var contextWindow: Int?
  public var maxInputTokens: Int?
  public var maxOutputTokens: Int?
  public var inputPricePerMillionUSD: Double?
  public var outputPricePerMillionUSD: Double?
  public var metadataSource: AIModelMetadataSource

  public init(
    id: String,
    name: String? = nil,
    isReasoning: Bool = false,
    isVision: Bool = false,
    isChat: Bool = true,
    contextWindow: Int? = nil,
    maxInputTokens: Int? = nil,
    maxOutputTokens: Int? = nil,
    inputPricePerMillionUSD: Double? = nil,
    outputPricePerMillionUSD: Double? = nil,
    metadataSource: AIModelMetadataSource = .heuristic
  ) {
    self.id = id
    self.name = name ?? id
    self.isReasoning = isReasoning
    self.isVision = isVision
    self.isChat = isChat
    self.contextWindow = contextWindow
    self.maxInputTokens = maxInputTokens
    self.maxOutputTokens = maxOutputTokens
    self.inputPricePerMillionUSD = inputPricePerMillionUSD
    self.outputPricePerMillionUSD = outputPricePerMillionUSD
    self.metadataSource = metadataSource
  }

  private enum CodingKeys: String, CodingKey {
    case id, name, isReasoning, isVision, isChat
    case contextWindow, maxInputTokens, maxOutputTokens
    case inputPricePerMillionUSD, outputPricePerMillionUSD, metadataSource
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let id = try container.decode(String.self, forKey: .id)
    self.init(
      id: id,
      name: try container.decodeIfPresent(String.self, forKey: .name),
      isReasoning: try container.decodeIfPresent(Bool.self, forKey: .isReasoning) ?? false,
      isVision: try container.decodeIfPresent(Bool.self, forKey: .isVision) ?? false,
      isChat: try container.decodeIfPresent(Bool.self, forKey: .isChat) ?? true,
      contextWindow: try container.decodeIfPresent(Int.self, forKey: .contextWindow),
      maxInputTokens: try container.decodeIfPresent(Int.self, forKey: .maxInputTokens),
      maxOutputTokens: try container.decodeIfPresent(Int.self, forKey: .maxOutputTokens),
      inputPricePerMillionUSD: try container.decodeIfPresent(
        Double.self, forKey: .inputPricePerMillionUSD),
      outputPricePerMillionUSD: try container.decodeIfPresent(
        Double.self, forKey: .outputPricePerMillionUSD),
      metadataSource: try container.decodeIfPresent(
        AIModelMetadataSource.self, forKey: .metadataSource
      ) ?? .heuristic
    )
  }

  public var hasProviderMetadata: Bool { metadataSource == .provider }

  public var badgeTitle: String? {
    if isReasoning {
      return "深度思考"
    }
    if isVision {
      return "多模态"
    }
    return nil
  }
}
