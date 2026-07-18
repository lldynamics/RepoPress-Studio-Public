import Foundation

public enum ProEntitlementSource: String, Codable, CaseIterable, Identifiable, Sendable {
  case none
  case storeKit

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .none:
      return "未解锁"
    case .storeKit:
      return "StoreKit"
    }
  }

  public init(from decoder: Decoder) throws {
    let value = try decoder.singleValueContainer().decode(String.self)
    self = ProEntitlementSource(rawValue: value) ?? .none
  }
}

public protocol ProEntitlementProviding: Sendable {
  func entitlement(restoring persistedEntitlement: ProEntitlementState) -> ProEntitlementState
}

/// Production persistence never restores an unlocked flag by itself. StoreKit must
/// re-verify the current transaction after launch before Pro features are enabled.
public struct VerifiedStoreKitEntitlementProvider: ProEntitlementProviding {
  public init() {}

  public func entitlement(restoring persistedEntitlement: ProEntitlementState) -> ProEntitlementState {
    var locked = ProEntitlementState.locked
    locked.lastCheckedAt = persistedEntitlement.lastCheckedAt
    return locked
  }
}

public struct ProEntitlementState: Codable, Hashable, Sendable {
  public var isUnlocked: Bool
  public var source: ProEntitlementSource
  public var productID: String?
  public var unlockedAt: Date?
  public var lastCheckedAt: Date?

  public init(
    isUnlocked: Bool = false,
    source: ProEntitlementSource = .none,
    productID: String? = nil,
    unlockedAt: Date? = nil,
    lastCheckedAt: Date? = nil
  ) {
    self.isUnlocked = isUnlocked
    self.source = source
    self.productID = productID
    self.unlockedAt = unlockedAt
    self.lastCheckedAt = lastCheckedAt
  }

  public static var locked: ProEntitlementState {
    ProEntitlementState()
  }
}

public struct FreePlanUsage: Codable, Hashable, Sendable {
  public var aiRequestCount: Int
  public var onlinePublishAttemptCount: Int
  public var batchPublishCount: Int

  public init(
    aiRequestCount: Int = 0,
    onlinePublishAttemptCount: Int = 0,
    batchPublishCount: Int = 0
  ) {
    self.aiRequestCount = aiRequestCount
    self.onlinePublishAttemptCount = onlinePublishAttemptCount
    self.batchPublishCount = batchPublishCount
  }
}

public struct MonetizationState: Codable, Hashable, Sendable {
  public var entitlement: ProEntitlementState
  public var freeUsage: FreePlanUsage

  public init(
    entitlement: ProEntitlementState = .locked,
    freeUsage: FreePlanUsage = FreePlanUsage()
  ) {
    self.entitlement = entitlement
    self.freeUsage = freeUsage
  }

  public static var `default`: MonetizationState {
    MonetizationState()
  }

  private enum CodingKeys: String, CodingKey {
    case entitlement
    case freeUsage
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    entitlement = try container.decodeIfPresent(ProEntitlementState.self, forKey: .entitlement) ?? .locked
    freeUsage = try container.decodeIfPresent(FreePlanUsage.self, forKey: .freeUsage) ?? FreePlanUsage()
  }
}
public struct FreePlanLimits: Codable, Hashable, Sendable {
  public var aiRequestLimit: Int
  public var onlinePublishAttemptLimit: Int
  public var batchPublishLimit: Int

  public init(
    aiRequestLimit: Int = 10,
    onlinePublishAttemptLimit: Int = 0,
    batchPublishLimit: Int = 2
  ) {
    self.aiRequestLimit = aiRequestLimit
    self.onlinePublishAttemptLimit = onlinePublishAttemptLimit
    self.batchPublishLimit = batchPublishLimit
  }

  public static var `default`: FreePlanLimits {
    FreePlanLimits()
  }
}

public enum PremiumFeature: String, Codable, CaseIterable, Identifiable, Sendable {
  case aiRequest
  case onlinePublishing
  case batchPublishing

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .aiRequest:
      return "AI 请求"
    case .onlinePublishing:
      return "GitHub/GitLab 线上发布"
    case .batchPublishing:
      return "批量发布"
    }
  }

  public var proBenefit: String {
    switch self {
    case .aiRequest:
      return "更多 AI 写作、SEO、图片和发布检查请求"
    case .onlinePublishing:
      return "通过 GitHub/GitLab API 直接提交、创建 PR/MR 和记录部署结果"
    case .batchPublishing:
      return "批量写入、批量线上发布和跨文章发布队列"
    }
  }

  public var systemImage: String {
    switch self {
    case .aiRequest:
      return "sparkles"
    case .onlinePublishing:
      return "network"
    case .batchPublishing:
      return "square.stack.3d.down.right"
    }
  }
}

public struct ProUpgradePresentation: Hashable, Sendable {
  public var title: String
  public var message: String
  public var benefits: [String]
  public var actionTitle: String

  public init(
    title: String = "解锁 Pro",
    message: String = "Pro 解锁线上发布、更多 AI 请求和批量发布能力。",
    benefits: [String] = PremiumFeature.allCases.map(\.proBenefit),
    actionTitle: String = "前往 Pro 设置"
  ) {
    self.title = title
    self.message = message
    self.benefits = benefits
    self.actionTitle = actionTitle
  }

  public static var `default`: ProUpgradePresentation {
    ProUpgradePresentation()
  }
}

public struct ProStatusSummary: Hashable, Sendable {
  public var productID: String
  public var entitlement: ProEntitlementState
  public var requirements: [ProUpgradeRequirement]

  public init(
    productID: String = MonetizationProductCatalog.proLifetimeProductID,
    entitlement: ProEntitlementState,
    requirements: [ProUpgradeRequirement]
  ) {
    self.productID = productID
    self.entitlement = entitlement
    self.requirements = requirements
  }

  public var blockedRequirements: [ProUpgradeRequirement] {
    requirements.filter(\.isBlocking)
  }

  public var availableRequirements: [ProUpgradeRequirement] {
    requirements.filter { !$0.isBlocking }
  }

  public var isActionRequired: Bool {
    !entitlement.isUnlocked && !blockedRequirements.isEmpty
  }

  public var title: String {
    if entitlement.isUnlocked {
      return "Pro 已解锁"
    }
    if blockedRequirements.isEmpty {
      return "免费额度可用"
    }
    return "\(blockedRequirements.count) 项功能需要 Pro"
  }

  public var message: String {
    if entitlement.isUnlocked {
      return "\(entitlement.source.displayName) 权益已生效，AI、线上发布和批量发布不会消耗免费额度。"
    }
    if blockedRequirements.isEmpty {
      return "当前免费额度仍可覆盖已配置的 Pro 功能边界。"
    }
    let names = blockedRequirements.map { $0.feature.displayName }.joined(separator: "、")
    return "\(names) 已达到免费版边界。"
  }

  public var nextStep: String {
    if entitlement.isUnlocked {
      return "可直接继续发布；如切换设备，可用恢复购买重新应用权益。"
    }
    if blockedRequirements.isEmpty {
      return "继续试用；额度用完时再到 Pro 设置购买或恢复。"
    }
    return "前往 Pro 设置购买或恢复后继续使用受限功能。"
  }

  public var systemImage: String {
    entitlement.isUnlocked ? "crown.fill" : (isActionRequired ? "lock.fill" : "person")
  }

  public var checklistMarkdown: String {
    var lines = [
      "# Pro 状态摘要",
      "",
      "- 产品 ID：\(productID)",
      "- 状态：\(title)",
      "- 权益来源：\(entitlement.source.displayName)",
      "- 说明：\(message)",
      "- 下一步：\(nextStep)",
      "",
      "## 功能边界"
    ]

    if requirements.isEmpty {
      lines.append("- 未配置 Pro 功能门槛。")
    } else {
      for requirement in requirements {
        let status = requirement.isBlocking ? "需要 Pro" : "可用"
        lines.append("- \(requirement.feature.displayName)：\(status)；\(requirement.quotaSummary)")
      }
    }

    return lines.joined(separator: "\n")
  }
}

public struct FeatureAccessDecision: Codable, Hashable, Sendable {
  public var feature: PremiumFeature
  public var isAllowed: Bool
  public var requiresPro: Bool
  public var remainingFreeUses: Int?
  public var title: String
  public var message: String

  public init(
    feature: PremiumFeature,
    isAllowed: Bool,
    requiresPro: Bool,
    remainingFreeUses: Int?,
    title: String,
    message: String
  ) {
    self.feature = feature
    self.isAllowed = isAllowed
    self.requiresPro = requiresPro
    self.remainingFreeUses = remainingFreeUses
    self.title = title
    self.message = message
  }
}

public struct ProFeatureBlockNotice: Identifiable, Hashable, Sendable {
  public var feature: PremiumFeature
  public var title: String
  public var message: String
  public var nextStep: String
  public var createdAt: Date

  public var id: PremiumFeature { feature }

  public init(
    feature: PremiumFeature,
    title: String,
    message: String,
    nextStep: String,
    createdAt: Date = Date()
  ) {
    self.feature = feature
    self.title = title
    self.message = message
    self.nextStep = nextStep
    self.createdAt = createdAt
  }

  public init(decision: FeatureAccessDecision, createdAt: Date = Date()) {
    self.init(
      feature: decision.feature,
      title: decision.title,
      message: decision.message,
      nextStep: "在 Pro 设置中购买或恢复后继续使用\(decision.feature.displayName)。",
      createdAt: createdAt
    )
  }
}

public struct ProUpgradeRequirement: Codable, Hashable, Sendable, Identifiable {
  public var feature: PremiumFeature
  public var isBlocking: Bool
  public var title: String
  public var summary: String
  public var quotaSummary: String
  public var usedFreeUses: Int
  public var freeLimit: Int
  public var remainingFreeUses: Int
  public var reason: String
  public var nextStep: String

  public var id: PremiumFeature { feature }

  public init(
    feature: PremiumFeature,
    isBlocking: Bool,
    title: String,
    summary: String,
    quotaSummary: String,
    usedFreeUses: Int = 0,
    freeLimit: Int = 0,
    remainingFreeUses: Int = 0,
    reason: String,
    nextStep: String
  ) {
    self.feature = feature
    self.isBlocking = isBlocking
    self.title = title
    self.summary = summary
    self.quotaSummary = quotaSummary
    self.usedFreeUses = usedFreeUses
    self.freeLimit = freeLimit
    self.remainingFreeUses = remainingFreeUses
    self.reason = reason
    self.nextStep = nextStep
  }

  public var checklistLine: String {
    let status = isBlocking ? "需要 Pro" : "可用"
    return "- [\(isBlocking ? " " : "x")] \(feature.displayName)：\(status)；\(quotaSummary)；\(nextStep)"
  }
}

public enum MonetizationProductCatalog {
  public static let proLifetimeProductID = "personal.site.publisher.pro"
}

public struct MonetizationService {
  public var limits: FreePlanLimits

  public init(limits: FreePlanLimits = .default) {
    self.limits = limits
  }

  public func accessDecision(
    for feature: PremiumFeature,
    state: MonetizationState
  ) -> FeatureAccessDecision {
    let used = usedFreeUses(for: feature, usage: state.freeUsage)
    let limit = freeLimit(for: feature)
    if state.entitlement.isUnlocked {
      return FeatureAccessDecision(
        feature: feature,
        isAllowed: true,
        requiresPro: false,
        remainingFreeUses: nil,
        title: "Pro 已解锁",
        message: "\(feature.displayName)可用。"
      )
    }

    let remaining = remainingFreeUses(for: feature, usage: state.freeUsage)
    if remaining > 0 {
      return FeatureAccessDecision(
        feature: feature,
        isAllowed: true,
        requiresPro: false,
        remainingFreeUses: remaining,
        title: "免费额度可用",
        message: "\(feature.displayName)还剩 \(remaining) 次免费额度（已用 \(used)/\(limit)）。"
      )
    }

    return FeatureAccessDecision(
      feature: feature,
      isAllowed: false,
      requiresPro: true,
      remainingFreeUses: 0,
      title: "需要 Pro",
      message: "\(feature.displayName)已达到免费版边界（已用 \(used)/\(limit)）。解锁 Pro 可使用\(feature.proBenefit)。请在 Pro 设置中购买或恢复。"
    )
  }

  public func upgradeRequirement(
    for feature: PremiumFeature,
    state: MonetizationState
  ) -> ProUpgradeRequirement {
    let decision = accessDecision(for: feature, state: state)
    let used = usedFreeUses(for: feature, usage: state.freeUsage)
    let limit = freeLimit(for: feature)
    let remaining = state.entitlement.isUnlocked ? 0 : remainingFreeUses(for: feature, usage: state.freeUsage)
    let quotaSummary: String
    if state.entitlement.isUnlocked {
      quotaSummary = "Pro 已解锁，不消耗免费额度"
    } else if let remaining = decision.remainingFreeUses {
      quotaSummary = "已用 \(used)/\(limit)，剩余 \(remaining) 次"
    } else {
      quotaSummary = "免费额度不限制当前 Pro 权限"
    }

    let reason: String
    let nextStep: String
    if decision.requiresPro {
      reason = feature.proBenefit
      nextStep = "前往 Pro 设置购买或恢复后继续使用"
    } else if state.entitlement.isUnlocked {
      reason = "当前设备已具备 Pro 权限"
      nextStep = "可直接使用，无需升级"
    } else {
      reason = "当前免费额度仍可覆盖此操作"
      nextStep = "额度用完前可继续试用"
    }

    return ProUpgradeRequirement(
      feature: feature,
      isBlocking: !decision.isAllowed && decision.requiresPro,
      title: decision.title,
      summary: decision.message,
      quotaSummary: quotaSummary,
      usedFreeUses: used,
      freeLimit: limit,
      remainingFreeUses: remaining,
      reason: reason,
      nextStep: nextStep
    )
  }

  public func upgradeRequirements(state: MonetizationState) -> [ProUpgradeRequirement] {
    PremiumFeature.allCases.map { feature in
      upgradeRequirement(for: feature, state: state)
    }
  }

  public func statusSummary(state: MonetizationState) -> ProStatusSummary {
    ProStatusSummary(
      entitlement: state.entitlement,
      requirements: upgradeRequirements(state: state)
    )
  }

  public func consuming(
    _ feature: PremiumFeature,
    state: MonetizationState
  ) -> MonetizationState {
    guard !state.entitlement.isUnlocked else {
      return state
    }

    var updated = state
    switch feature {
    case .aiRequest:
      updated.freeUsage.aiRequestCount += 1
    case .onlinePublishing:
      updated.freeUsage.onlinePublishAttemptCount += 1
    case .batchPublishing:
      updated.freeUsage.batchPublishCount += 1
    }
    return updated
  }

  public func remainingFreeUses(for feature: PremiumFeature, usage: FreePlanUsage) -> Int {
    switch feature {
    case .aiRequest:
      return max(0, limits.aiRequestLimit - usage.aiRequestCount)
    case .onlinePublishing:
      return max(0, limits.onlinePublishAttemptLimit - usage.onlinePublishAttemptCount)
    case .batchPublishing:
      return max(0, limits.batchPublishLimit - usage.batchPublishCount)
    }
  }

  public func usedFreeUses(for feature: PremiumFeature, usage: FreePlanUsage) -> Int {
    switch feature {
    case .aiRequest:
      return usage.aiRequestCount
    case .onlinePublishing:
      return usage.onlinePublishAttemptCount
    case .batchPublishing:
      return usage.batchPublishCount
    }
  }

  public func freeLimit(for feature: PremiumFeature) -> Int {
    switch feature {
    case .aiRequest:
      return limits.aiRequestLimit
    case .onlinePublishing:
      return limits.onlinePublishAttemptLimit
    case .batchPublishing:
      return limits.batchPublishLimit
    }
  }
}
