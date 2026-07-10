import Foundation

public enum ProEntitlementSource: String, Codable, CaseIterable, Identifiable, Sendable {
  case none
  case storeKit
  case localOverride

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .none:
      return "未解锁"
    case .storeKit:
      return "StoreKit"
    case .localOverride:
      return "本机解锁"
    }
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
  public var recentAccessEvents: [MonetizationAccessEvent]

  public init(
    entitlement: ProEntitlementState = .locked,
    freeUsage: FreePlanUsage = FreePlanUsage(),
    recentAccessEvents: [MonetizationAccessEvent] = []
  ) {
    self.entitlement = entitlement
    self.freeUsage = freeUsage
    self.recentAccessEvents = Self.limitedAccessEvents(recentAccessEvents)
  }

  public static var `default`: MonetizationState {
    MonetizationState()
  }

  private enum CodingKeys: String, CodingKey {
    case entitlement
    case freeUsage
    case recentAccessEvents
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    entitlement = try container.decodeIfPresent(ProEntitlementState.self, forKey: .entitlement) ?? .locked
    freeUsage = try container.decodeIfPresent(FreePlanUsage.self, forKey: .freeUsage) ?? FreePlanUsage()
    recentAccessEvents = Self.limitedAccessEvents(
      try container.decodeIfPresent([MonetizationAccessEvent].self, forKey: .recentAccessEvents) ?? []
    )
  }

  public mutating func recordAccessEvent(_ event: MonetizationAccessEvent) {
    recentAccessEvents = Self.limitedAccessEvents([event] + recentAccessEvents)
  }

  public static func limitedAccessEvents(
    _ events: [MonetizationAccessEvent],
    limit: Int = 30
  ) -> [MonetizationAccessEvent] {
    Array(events.sorted { $0.createdAt > $1.createdAt }.prefix(limit))
  }
}

public enum MonetizationAccessEventOutcome: String, Codable, CaseIterable, Sendable {
  case allowedFreeUse
  case allowedProEntitlement
  case blockedRequiresPro

  public var displayName: String {
    switch self {
    case .allowedFreeUse:
      return "免费额度放行"
    case .allowedProEntitlement:
      return "Pro 放行"
    case .blockedRequiresPro:
      return "需要 Pro"
    }
  }

  public var systemImage: String {
    switch self {
    case .allowedFreeUse:
      return "checkmark.circle"
    case .allowedProEntitlement:
      return "crown.fill"
    case .blockedRequiresPro:
      return "lock.fill"
    }
  }
}

public struct MonetizationAccessEvent: Codable, Hashable, Identifiable, Sendable {
  public var id: UUID
  public var feature: PremiumFeature
  public var outcome: MonetizationAccessEventOutcome
  public var usedFreeUsesBeforeAction: Int
  public var freeLimit: Int
  public var remainingFreeUsesAfterAction: Int?
  public var message: String
  public var createdAt: Date

  public init(
    id: UUID = UUID(),
    feature: PremiumFeature,
    outcome: MonetizationAccessEventOutcome,
    usedFreeUsesBeforeAction: Int,
    freeLimit: Int,
    remainingFreeUsesAfterAction: Int?,
    message: String,
    createdAt: Date = Date()
  ) {
    self.id = id
    self.feature = feature
    self.outcome = outcome
    self.usedFreeUsesBeforeAction = usedFreeUsesBeforeAction
    self.freeLimit = freeLimit
    self.remainingFreeUsesAfterAction = remainingFreeUsesAfterAction
    self.message = message
    self.createdAt = createdAt
  }

  public var quotaSummary: String {
    if let remainingFreeUsesAfterAction {
      return "操作前已用 \(usedFreeUsesBeforeAction)/\(freeLimit)，操作后剩余 \(remainingFreeUsesAfterAction) 次"
    }
    return "Pro 已解锁，未消耗免费额度"
  }

  public var checklistLine: String {
    "- \(feature.displayName)：\(outcome.displayName)；\(quotaSummary)"
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

public struct ProMonetizationAuditReport: Hashable, Sendable {
  public var state: MonetizationState
  public var requirements: [ProUpgradeRequirement]
  public var productID: String

  public init(
    state: MonetizationState,
    requirements: [ProUpgradeRequirement],
    productID: String = MonetizationProductCatalog.proLifetimeProductID
  ) {
    self.state = state
    self.requirements = requirements
    self.productID = productID
  }

  public var checklistMarkdown: String {
    var lines: [String] = [
      "# StoreKit / Pro 边界审核清单",
      "",
      "- 产品 ID：\(productID)",
      "- 权益状态：\(state.entitlement.isUnlocked ? "Pro 已解锁" : "免费版")",
      "- 权益来源：\(state.entitlement.source.displayName)",
      "- AI 请求已用：\(state.freeUsage.aiRequestCount)",
      "- 线上发布已用：\(state.freeUsage.onlinePublishAttemptCount)",
      "- 批量发布已用：\(state.freeUsage.batchPublishCount)",
      "",
      "## 功能门槛"
    ]

    if requirements.isEmpty {
      lines.append("- 未配置 Pro 功能门槛。")
    } else {
      lines.append(contentsOf: requirements.map(\.checklistLine))
    }

    lines.append("")
    lines.append("## 最近使用记录")
    if state.recentAccessEvents.isEmpty {
      lines.append("- 暂无 AI、线上发布或批量发布的免费版/Pro 边界记录。")
    } else {
      lines.append(contentsOf: state.recentAccessEvents.prefix(10).map(\.checklistLine))
    }

    lines.append("")
    lines.append("## StoreKit Sandbox 核对")
    lines.append("- [ ] StoreKit 配置包含 \(productID)。")
    lines.append("- [ ] 免费版触发 AI、GitHub/GitLab 线上发布和批量发布边界时显示升级原因。")
    lines.append("- [ ] 购买成功后权益来源为 StoreKit，免费额度不再消耗。")
    lines.append("- [ ] 恢复购买成功后可以重新应用 Pro 权益。")
    lines.append("- [ ] 没有可恢复购买时显示明确提示，不误标记为 Pro。")

    return lines.joined(separator: "\n")
  }
}

public struct ProStoreKitReviewEvidencePackage: Hashable, Sendable {
  public var statusSummary: ProStatusSummary
  public var auditReport: ProMonetizationAuditReport
  public var sandboxSummary: ProSandboxVerificationSummary

  public init(
    statusSummary: ProStatusSummary,
    auditReport: ProMonetizationAuditReport,
    sandboxSummary: ProSandboxVerificationSummary
  ) {
    self.statusSummary = statusSummary
    self.auditReport = auditReport
    self.sandboxSummary = sandboxSummary
  }

  public var checklistMarkdown: String {
    let lines: [String] = [
      "# StoreKit / Pro 上架证据包",
      "",
      "- 产品 ID：\(statusSummary.productID)",
      "- Pro 状态：\(statusSummary.title)",
      "- 权益来源：\(statusSummary.entitlement.source.displayName)",
      "- Sandbox 核验：\(sandboxSummary.level.displayName)",
      "- 待处理项：\(sandboxSummary.remainingItems.count)",
      "- 免费版受限项：\(statusSummary.blockedRequirements.count)",
      "",
      "## App Review 说明",
      "- Pro 是非消耗型解锁项，用于 GitHub/GitLab 线上发布、更多 AI 请求和批量发布能力。",
      "- 购买入口、恢复购买入口和当前权益检查都在 Pro 设置页。",
      "- 免费版达到边界时会先显示升级原因，不会静默扣除或绕过 StoreKit。",
      "- Pro 权益来源必须是 StoreKit；本机解锁只作为调试状态，不作为审核证据。",
      "",
      "## 当前 Pro 状态",
      statusSummary.checklistMarkdown,
      "",
      "## StoreKit / Pro 边界审核",
      auditReport.checklistMarkdown,
      "",
      "## StoreKit Sandbox 核验",
      sandboxSummary.checklistMarkdown,
      "",
      "## 外部验证字段",
      sandboxSummary.externalVerificationEvidenceMarkdown,
      "",
      "## 建议验证命令",
      "```sh",
      "bash script/check_storekit.sh",
      "bash script/capture_app_screenshots.sh --only pro-settings --force-relaunch",
      "bash script/record_storekit_sandbox_evidence.sh --dry-run",
      "```",
      "",
      "## 实测记录命令模板",
      sandboxSummary.externalVerificationRecordingCommandMarkdown,
      "",
      "## 提交前检查",
      "- [ ] StoreKit 产品能在 sandbox 读取到 \(statusSummary.productID)。",
      "- [ ] 购买成功后权益来源显示为 StoreKit。",
      "- [ ] 恢复购买成功和无可恢复购买两条路径都有明确提示。",
      "- [ ] 免费版阻断事件和 Pro 放行事件都进入最近使用记录。",
      "- [ ] Pro 设置截图不包含账号、交易号、Token 或本机隐私路径。"
    ]

    return lines.joined(separator: "\n")
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

public enum ProSandboxVerificationLevel: String, CaseIterable, Hashable, Sendable {
  case verified
  case readyToVerify
  case needsAttention

  public var displayName: String {
    switch self {
    case .verified:
      return "已验证"
    case .readyToVerify:
      return "待沙盒验证"
    case .needsAttention:
      return "需要处理"
    }
  }

  public var systemImage: String {
    switch self {
    case .verified:
      return "checkmark.seal"
    case .readyToVerify:
      return "testtube.2"
    case .needsAttention:
      return "exclamationmark.triangle"
    }
  }
}

public struct ProBoundaryEvidenceSummary: Hashable, Sendable {
  public var latestFreeUse: MonetizationAccessEvent?
  public var latestBlockedUse: MonetizationAccessEvent?
  public var latestProUse: MonetizationAccessEvent?

  public init(events: [MonetizationAccessEvent]) {
    let sortedEvents = events.sorted { $0.createdAt > $1.createdAt }
    latestFreeUse = sortedEvents.first { $0.outcome == .allowedFreeUse }
    latestBlockedUse = sortedEvents.first { $0.outcome == .blockedRequiresPro }
    latestProUse = sortedEvents.first { $0.outcome == .allowedProEntitlement }
  }

  public var hasUpgradePromptEvidence: Bool {
    latestBlockedUse != nil
  }

  public var hasProNoQuotaEvidence: Bool {
    guard let latestProUse else {
      return false
    }
    return latestProUse.remainingFreeUsesAfterAction == nil
  }

  public var title: String {
    if hasUpgradePromptEvidence && hasProNoQuotaEvidence {
      return "免费边界和 Pro 放行都有事件证据"
    }
    if hasUpgradePromptEvidence {
      return "已有免费版阻断证据"
    }
    if hasProNoQuotaEvidence {
      return "已有 Pro 放行证据"
    }
    return "缺少边界事件证据"
  }

  public var message: String {
    if hasUpgradePromptEvidence && hasProNoQuotaEvidence {
      return "最近使用记录能证明购买前会提示升级，购买后受限功能不会继续消耗免费额度。"
    }
    if hasUpgradePromptEvidence {
      return "还需要 Pro 解锁后执行一次 AI、线上发布或批量发布，确认记录为 Pro 放行。"
    }
    if hasProNoQuotaEvidence {
      return "还需要在免费版状态触发一次边界阻断，确认升级提示和额度状态可追溯。"
    }
    return "请先在免费版触发一次受限功能，再在 Pro 解锁后执行一次同类功能。"
  }

  public var verifiedItems: [String] {
    var items: [String] = []
    if let latestBlockedUse {
      items.append("已记录免费版阻断事件：\(latestBlockedUse.feature.displayName)，\(latestBlockedUse.quotaSummary)。")
    }
    if let latestProUse, hasProNoQuotaEvidence {
      items.append("已记录 Pro 放行事件：\(latestProUse.feature.displayName)，未消耗免费额度。")
    }
    return items
  }

  public var remainingItems: [String] {
    var items: [String] = []
    if !hasUpgradePromptEvidence {
      items.append("在免费版触发一次受限功能，保留升级提示、已用额度和剩余额度。")
    }
    if !hasProNoQuotaEvidence {
      items.append("Pro 解锁后执行一次受限功能，确认最近使用记录显示 Pro 放行且不消耗免费额度。")
    }
    return items
  }

  public var checklistMarkdown: String {
    var lines = [
      "## 免费版 / Pro 边界事件",
      "- 状态：\(title)",
      "- 说明：\(message)",
    ]
    if let latestBlockedUse {
      lines.append("- 免费版阻断：\(latestBlockedUse.feature.displayName)；\(latestBlockedUse.quotaSummary)")
    } else {
      lines.append("- 免费版阻断：未记录")
    }
    if let latestProUse {
      lines.append("- Pro 放行：\(latestProUse.feature.displayName)；\(latestProUse.quotaSummary)")
    } else {
      lines.append("- Pro 放行：未记录")
    }
    if let latestFreeUse {
      lines.append("- 免费额度放行：\(latestFreeUse.feature.displayName)；\(latestFreeUse.quotaSummary)")
    }
    return lines.joined(separator: "\n")
  }

  public var externalEvidenceLine: String {
    let blocked = latestBlockedUse.map {
      "blocked \($0.feature.displayName) with \($0.quotaSummary)"
    } ?? "missing free-plan block event"
    let pro = latestProUse.map {
      "Pro allowed \($0.feature.displayName) with \($0.remainingFreeUsesAfterAction == nil ? "no free quota consumption" : $0.quotaSummary)"
    } ?? "missing Pro no-quota event"
    return "\(blocked); \(pro)."
  }
}

public struct ProSandboxVerificationSummary: Hashable, Sendable {
  public var productID: String
  public var level: ProSandboxVerificationLevel
  public var title: String
  public var message: String
  public var verifiedItems: [String]
  public var remainingItems: [String]
  public var boundaryEvidence: ProBoundaryEvidenceSummary
  public var blockingRequirementCount: Int
  public var lastCheckedAt: Date?

  public init(
    productID: String = MonetizationProductCatalog.proLifetimeProductID,
    level: ProSandboxVerificationLevel,
    title: String,
    message: String,
    verifiedItems: [String],
    remainingItems: [String],
    boundaryEvidence: ProBoundaryEvidenceSummary,
    blockingRequirementCount: Int,
    lastCheckedAt: Date?
  ) {
    self.productID = productID
    self.level = level
    self.title = title
    self.message = message
    self.verifiedItems = verifiedItems
    self.remainingItems = remainingItems
    self.boundaryEvidence = boundaryEvidence
    self.blockingRequirementCount = blockingRequirementCount
    self.lastCheckedAt = lastCheckedAt
  }

  public static func make(
    state: MonetizationState,
    requirements: [ProUpgradeRequirement],
    productID: String = MonetizationProductCatalog.proLifetimeProductID
  ) -> ProSandboxVerificationSummary {
    var verifiedItems = [
      "StoreKit 产品 ID 已纳入配置：\(productID)。",
      "Pro 设置页提供购买和恢复入口。",
    ]
    var remainingItems: [String] = []
    let boundaryEvidence = ProBoundaryEvidenceSummary(events: state.recentAccessEvents)

    let blockingCount = requirements.filter(\.isBlocking).count
    if blockingCount > 0 {
      remainingItems.append("触发 \(blockingCount) 项免费版边界，确认升级提示包含购买或恢复路径。")
    } else {
      verifiedItems.append("免费额度和 Pro 功能边界已在设置页展示。")
    }

    let entitlementProductMatches = state.entitlement.productID == productID
    if state.entitlement.isUnlocked {
      switch state.entitlement.source {
      case .storeKit:
        if entitlementProductMatches {
          verifiedItems.append("StoreKit 权益已应用到 Pro 状态。")
        } else {
          let currentProduct = state.entitlement.productID?.nilIfEmpty ?? "未记录"
          remainingItems.append("StoreKit 权益 product ID 为 \(currentProduct)，需要匹配 \(productID)。")
        }
      case .localOverride:
        remainingItems.append("本机解锁只能用于调试，不能替代 StoreKit sandbox 购买验收。")
      case .none:
        remainingItems.append("权益状态已解锁但来源为空，需要重新检查 StoreKit 权益来源。")
      }
    } else {
      remainingItems.append("使用 StoreKit sandbox 完成一次购买，并确认权益来源为 StoreKit。")
    }

    if state.entitlement.lastCheckedAt == nil {
      remainingItems.append("执行恢复购买或权益刷新，确认无可恢复购买时不会误标记为 Pro。")
    } else {
      verifiedItems.append("已记录最近一次 StoreKit 权益检查。")
    }
    verifiedItems.append(contentsOf: boundaryEvidence.verifiedItems)
    remainingItems.append(contentsOf: boundaryEvidence.remainingItems)

    let level: ProSandboxVerificationLevel
    if state.entitlement.isUnlocked,
       state.entitlement.source == .storeKit,
       entitlementProductMatches,
       state.entitlement.lastCheckedAt != nil,
       remainingItems.isEmpty {
      level = .verified
    } else if state.entitlement.source == .localOverride
      || (state.entitlement.isUnlocked && state.entitlement.source == .none)
      || (state.entitlement.isUnlocked && state.entitlement.source == .storeKit && !entitlementProductMatches) {
      level = .needsAttention
    } else {
      level = .readyToVerify
    }

    let title: String
    let message: String
    switch level {
    case .verified:
      title = "StoreKit 沙盒链路已验证"
      message = "Pro 产品、购买权益和恢复检查都有当前状态证据。"
    case .readyToVerify:
      title = "等待 StoreKit 沙盒验收"
      message = "产品和入口已就绪，还需要在 sandbox 中完成购买、恢复和免费边界确认。"
    case .needsAttention:
      title = "StoreKit 验收需要处理"
      message = "当前 Pro 状态不能作为 App Store sandbox 验收证据。"
    }

    return ProSandboxVerificationSummary(
      productID: productID,
      level: level,
      title: title,
      message: message,
      verifiedItems: verifiedItems,
      remainingItems: remainingItems,
      boundaryEvidence: boundaryEvidence,
      blockingRequirementCount: blockingCount,
      lastCheckedAt: state.entitlement.lastCheckedAt
    )
  }

  public var checklistMarkdown: String {
    var lines = [
      "# StoreKit Sandbox 核验摘要",
      "",
      "- 产品 ID：\(productID)",
      "- 状态：\(level.displayName)",
      "- 结论：\(title)",
      "- 说明：\(message)",
      "- 阻塞中的免费版边界：\(blockingRequirementCount)",
      "- 最近权益检查：\(lastCheckedAt == nil ? "未记录" : "已记录")",
      "",
      "## 已有证据",
    ]

    lines.append(contentsOf: verifiedItems.map { "- [x] \($0)" })
    lines.append("")
    lines.append("## 待核验")
    if remainingItems.isEmpty {
      lines.append("- 当前没有待核验项。")
    } else {
      lines.append(contentsOf: remainingItems.map { "- [ ] \($0)" })
    }
    lines.append("")
    lines.append(boundaryEvidence.checklistMarkdown)

    return lines.joined(separator: "\n")
  }

  public var externalVerificationEvidenceMarkdown: String {
    [
      "StoreKit product lookup: \(productLookupEvidence)",
      "StoreKit purchase: \(purchaseEvidence)",
      "StoreKit restore: \(restoreEvidence)",
      "StoreKit free quota: \(freeQuotaEvidence)",
      "StoreKit boundary events: \(boundaryEvidence.externalEvidenceLine)"
    ].joined(separator: "\n")
  }

  public var externalVerificationRecordingCommandMarkdown: String {
    [
      "# StoreKit Sandbox Evidence Recording Commands",
      "",
      "Use these commands only after sandbox product lookup, purchase, restore, and free quota boundary checks have actually been performed.",
      "",
      "```sh",
      "script/record_storekit_sandbox_evidence.sh --dry-run",
      "",
      "script/record_storekit_sandbox_evidence.sh \\",
      "  --product-lookup \"Sandbox product lookup loaded \(productID) from App Store sandbox catalog.\" \\",
      "  --purchase \"Purchase completed and entitlement source changed to StoreKit.\" \\",
      "  --restore \"Restore reapplied Pro entitlement after clearing local state.\" \\",
      "  --free-quota \"Free quota boundary showed upgrade copy before purchase and no quota consumption after Pro unlock.\" \\",
      "  --boundary-events \"Recent Pro boundary events showed free-plan block before purchase and Pro no-quota allow after unlock.\" \\",
      "  --execute",
      "```",
    ].joined(separator: "\n")
  }

  private var productLookupEvidence: String {
    if verifiedItems.contains(where: { $0.contains("StoreKit 权益已应用") }) {
      return "App Store sandbox transaction loaded product \(productID) and applied the matching StoreKit entitlement."
    }
    return "StoreKit configuration contains product \(productID); confirm App Store sandbox can load the same product ID before recording evidence."
  }

  private var purchaseEvidence: String {
    if verifiedItems.contains(where: { $0.contains("StoreKit 权益已应用") }) {
      return "Sandbox purchase or transaction update applied StoreKit entitlement for \(productID)."
    }
    return "Pending sandbox purchase; use the Pro settings purchase button and confirm entitlement source changes to StoreKit."
  }

  private var restoreEvidence: String {
    if lastCheckedAt != nil {
      return "StoreKit entitlement refresh/restore has been checked; verify restore either reapplies Pro or reports no recoverable purchase."
    }
    return "Pending restore check; use restore purchase and confirm the app does not mark Pro without a StoreKit entitlement."
  }

  private var freeQuotaEvidence: String {
    if verifiedItems.contains(where: { $0.contains("StoreKit 权益已应用") }) {
      return "StoreKit Pro entitlement is active; AI, online publishing, and batch publishing run without consuming free quota counters."
    }
    if blockingRequirementCount > 0 {
      return "\(blockingRequirementCount) free-plan boundary item(s) are blocking; confirm upgrade copy appears before purchase and quota stops increasing after Pro unlock."
    }
    return "Free quota boundary is not currently blocking; confirm Pro unlock leaves quota counters unchanged during AI, online publishing, and batch publishing."
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
