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
  public var dailyPeriodStartedAt: Date?

  public init(
    aiRequestCount: Int = 0,
    onlinePublishAttemptCount: Int = 0,
    batchPublishCount: Int = 0,
    dailyPeriodStartedAt: Date? = Date()
  ) {
    self.aiRequestCount = max(0, aiRequestCount)
    self.onlinePublishAttemptCount = max(0, onlinePublishAttemptCount)
    self.batchPublishCount = max(0, batchPublishCount)
    self.dailyPeriodStartedAt = dailyPeriodStartedAt
  }

  public func normalized(
    for date: Date,
    calendar: Calendar = .current
  ) -> FreePlanUsage {
    guard let dailyPeriodStartedAt,
          calendar.isDate(dailyPeriodStartedAt, inSameDayAs: date)
    else {
      return FreePlanUsage(dailyPeriodStartedAt: date)
    }

    return FreePlanUsage(
      aiRequestCount: aiRequestCount,
      onlinePublishAttemptCount: onlinePublishAttemptCount,
      batchPublishCount: batchPublishCount,
      dailyPeriodStartedAt: dailyPeriodStartedAt
    )
  }

  private enum CodingKeys: String, CodingKey {
    case aiRequestCount
    case onlinePublishAttemptCount
    case batchPublishCount
    case dailyPeriodStartedAt
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      aiRequestCount: try container.decodeIfPresent(Int.self, forKey: .aiRequestCount) ?? 0,
      onlinePublishAttemptCount: try container.decodeIfPresent(
        Int.self,
        forKey: .onlinePublishAttemptCount
      ) ?? 0,
      batchPublishCount: try container.decodeIfPresent(Int.self, forKey: .batchPublishCount) ?? 0,
      // Legacy lifetime counters have no trustworthy day. Keeping nil lets
      // the first daily normalization reset them instead of blocking forever.
      dailyPeriodStartedAt: try container.decodeIfPresent(Date.self, forKey: .dailyPeriodStartedAt)
    )
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
    aiRequestLimit: Int = 33,
    onlinePublishAttemptLimit: Int = 1,
    batchPublishLimit: Int = 3
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
      return "当日免费额度仍可覆盖已配置的 Pro 功能边界，设备本地日期变化后会自动恢复。"
    }
    let names = blockedRequirements.map { $0.feature.displayName }.joined(separator: "、")
    return "\(names) 已达到免费版边界。"
  }

  public var nextStep: String {
    if entitlement.isUnlocked {
      return "可直接继续发布；如切换设备，可用恢复购买重新应用权益。"
    }
    if blockedRequirements.isEmpty {
      return "继续试用；今日额度用完后可等待次日自动恢复，或到 Pro 设置购买或恢复。"
    }
    return "等待设备本地日期变化后自动恢复，或前往 Pro 设置购买或恢复。"
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
    state: MonetizationState,
    at date: Date = Date(),
    calendar: Calendar = .current
  ) -> FeatureAccessDecision {
    let state = normalizedState(state, at: date, calendar: calendar)
    let used = usedFreeUses(
      for: feature,
      usage: state.freeUsage,
      at: date,
      calendar: calendar
    )
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

    let remaining = remainingFreeUses(
      for: feature,
      usage: state.freeUsage,
      at: date,
      calendar: calendar
    )
    if remaining > 0 {
      return FeatureAccessDecision(
        feature: feature,
        isAllowed: true,
        requiresPro: false,
        remainingFreeUses: remaining,
        title: "免费额度可用",
        message: "\(feature.displayName)今日还剩 \(remaining) 次免费额度（已用 \(used)/\(limit)）。"
      )
    }

    return FeatureAccessDecision(
      feature: feature,
      isAllowed: false,
      requiresPro: true,
      remainingFreeUses: 0,
      title: "需要 Pro",
      message: "\(feature.displayName)已达到免费版边界（今日已用 \(used)/\(limit)）。免费额度会在设备本地日期变化后自动恢复；解锁 Pro 可使用\(feature.proBenefit)。请在 Pro 设置中购买或恢复。"
    )
  }

  public func upgradeRequirement(
    for feature: PremiumFeature,
    state: MonetizationState,
    at date: Date = Date(),
    calendar: Calendar = .current
  ) -> ProUpgradeRequirement {
    let state = normalizedState(state, at: date, calendar: calendar)
    let decision = accessDecision(for: feature, state: state, at: date, calendar: calendar)
    let used = usedFreeUses(
      for: feature,
      usage: state.freeUsage,
      at: date,
      calendar: calendar
    )
    let limit = freeLimit(for: feature)
    let remaining = state.entitlement.isUnlocked
      ? 0
      : remainingFreeUses(
        for: feature,
        usage: state.freeUsage,
        at: date,
        calendar: calendar
      )
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
      nextStep = "等待设备本地日期变化后自动恢复，或前往 Pro 设置购买或恢复"
    } else if state.entitlement.isUnlocked {
      reason = "当前设备已具备 Pro 权限"
      nextStep = "可直接使用，无需升级"
    } else {
      reason = "当前免费额度仍可覆盖此操作"
      nextStep = "今日额度用完前可继续试用，次日自动恢复"
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

  public func upgradeRequirements(
    state: MonetizationState,
    at date: Date = Date(),
    calendar: Calendar = .current
  ) -> [ProUpgradeRequirement] {
    PremiumFeature.allCases.map { feature in
      upgradeRequirement(for: feature, state: state, at: date, calendar: calendar)
    }
  }

  public func statusSummary(
    state: MonetizationState,
    at date: Date = Date(),
    calendar: Calendar = .current
  ) -> ProStatusSummary {
    ProStatusSummary(
      entitlement: state.entitlement,
      requirements: upgradeRequirements(state: state, at: date, calendar: calendar)
    )
  }

  public func consuming(
    _ feature: PremiumFeature,
    state: MonetizationState,
    at date: Date = Date(),
    calendar: Calendar = .current
  ) -> MonetizationState {
    let state = normalizedState(state, at: date, calendar: calendar)
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

  public func remainingFreeUses(
    for feature: PremiumFeature,
    usage: FreePlanUsage,
    at date: Date = Date(),
    calendar: Calendar = .current
  ) -> Int {
    let usage = normalizedFreeUsage(usage, at: date, calendar: calendar)
    switch feature {
    case .aiRequest:
      return max(0, limits.aiRequestLimit - usage.aiRequestCount)
    case .onlinePublishing:
      return max(0, limits.onlinePublishAttemptLimit - usage.onlinePublishAttemptCount)
    case .batchPublishing:
      return max(0, limits.batchPublishLimit - usage.batchPublishCount)
    }
  }

  public func usedFreeUses(
    for feature: PremiumFeature,
    usage: FreePlanUsage,
    at date: Date = Date(),
    calendar: Calendar = .current
  ) -> Int {
    let usage = normalizedFreeUsage(usage, at: date, calendar: calendar)
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

  public func normalizedFreeUsage(
    _ usage: FreePlanUsage,
    at date: Date = Date(),
    calendar: Calendar = .current
  ) -> FreePlanUsage {
    usage.normalized(for: date, calendar: calendar)
  }

  public func normalizedState(
    _ state: MonetizationState,
    at date: Date = Date(),
    calendar: Calendar = .current
  ) -> MonetizationState {
    var normalized = state
    normalized.freeUsage = normalizedFreeUsage(state.freeUsage, at: date, calendar: calendar)
    return normalized
  }
}
