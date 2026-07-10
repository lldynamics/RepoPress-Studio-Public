import Foundation

public struct AIChatUsageSummary: Equatable, Sendable {
  public var promptTokens: Int
  public var completionTokens: Int
  public var totalTokens: Int
  public var measuredMessageCount: Int
  public var estimatedCostUSD: Decimal?
  public var pricingNote: String

  public init(
    promptTokens: Int,
    completionTokens: Int,
    totalTokens: Int,
    measuredMessageCount: Int,
    estimatedCostUSD: Decimal?,
    pricingNote: String
  ) {
    self.promptTokens = promptTokens
    self.completionTokens = completionTokens
    self.totalTokens = totalTokens
    self.measuredMessageCount = measuredMessageCount
    self.estimatedCostUSD = estimatedCostUSD
    self.pricingNote = pricingNote
  }

  public var hasUsage: Bool {
    totalTokens > 0 || promptTokens > 0 || completionTokens > 0
  }

  public var tokenDisplayText: String {
    guard hasUsage else {
      return "暂无 Token 用量"
    }
    return "\(totalTokens) tokens · 输入 \(promptTokens) · 输出 \(completionTokens)"
  }

  public var costDisplayText: String {
    guard let estimatedCostUSD else {
      return pricingNote
    }
    return "估算费用 \(Self.currencyFormatter.string(from: estimatedCostUSD as NSDecimalNumber) ?? "$0.00")"
  }

  private static let currencyFormatter: NumberFormatter = {
    let formatter = NumberFormatter()
    formatter.numberStyle = .currency
    formatter.currencyCode = "USD"
    formatter.minimumFractionDigits = 4
    formatter.maximumFractionDigits = 6
    return formatter
  }()
}

public enum AIChatUsageSummaryService {
  public static func summary(
    messages: [AIPublishingChatMessage],
    config: AIProviderConfig
  ) -> AIChatUsageSummary {
    let usages = messages.compactMap(\.tokenUsage)
    let promptTokens = usages.compactMap(\.promptTokens).reduce(0, +)
    let completionTokens = usages.compactMap(\.completionTokens).reduce(0, +)
    let explicitTotal = usages.compactMap(\.totalTokens).reduce(0, +)
    let inferredTotal = promptTokens + completionTokens
    let totalTokens = explicitTotal > 0 ? explicitTotal : inferredTotal
    let cost = estimatedCostUSD(
      promptTokens: promptTokens,
      completionTokens: completionTokens,
      config: config
    )
    return AIChatUsageSummary(
      promptTokens: promptTokens,
      completionTokens: completionTokens,
      totalTokens: totalTokens,
      measuredMessageCount: usages.count,
      estimatedCostUSD: cost,
      pricingNote: pricingNote(for: config, hasUsage: totalTokens > 0)
    )
  }

  private static func estimatedCostUSD(
    promptTokens: Int,
    completionTokens: Int,
    config: AIProviderConfig
  ) -> Decimal? {
    guard let pricing = pricing(for: config) else {
      return nil
    }
    let input = Decimal(promptTokens) / 1_000_000 * pricing.inputPerMillionUSD
    let output = Decimal(completionTokens) / 1_000_000 * pricing.outputPerMillionUSD
    return input + output
  }

  private static func pricing(for config: AIProviderConfig) -> AIChatModelPricing? {
    if config.preset == .local {
      return AIChatModelPricing(inputPerMillionUSD: 0, outputPerMillionUSD: 0)
    }
    return nil
  }

  private static func pricingNote(for config: AIProviderConfig, hasUsage: Bool) -> String {
    guard hasUsage else {
      return "等待模型返回 usage 后统计"
    }
    if config.preset == .local {
      return "本地模型按 0 美元估算"
    }
    return "费用需按当前服务商和模型价格确认"
  }
}

private struct AIChatModelPricing {
  var inputPerMillionUSD: Decimal
  var outputPerMillionUSD: Decimal
}
