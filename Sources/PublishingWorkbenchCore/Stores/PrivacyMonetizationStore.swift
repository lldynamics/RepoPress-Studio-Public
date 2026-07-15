import Combine
import Foundation

@MainActor
public final class PrivacyMonetizationStore: ObservableObject {
  private let monetizationService: MonetizationService

  @Published public internal(set) var privacySettings: PrivacyProtectionSettings
  @Published public internal(set) var isPrivacyLocked: Bool
  @Published public internal(set) var privacyProtectionEvents: [PrivacyProtectionEvent]
  @Published public internal(set) var privacyLockReason: String?
  @Published public internal(set) var monetizationState: MonetizationState
  @Published public internal(set) var monetizationMessage: String?
  @Published public internal(set) var latestProFeatureBlockNotice: ProFeatureBlockNotice?

  init(
    privacySettings: PrivacyProtectionSettings = .default,
    isPrivacyLocked: Bool = false,
    privacyProtectionEvents: [PrivacyProtectionEvent] = [],
    privacyLockReason: String? = nil,
    monetizationState: MonetizationState = .default,
    monetizationMessage: String? = nil,
    latestProFeatureBlockNotice: ProFeatureBlockNotice? = nil,
    monetizationService: MonetizationService = MonetizationService(),
    entitlementProvider: any ProEntitlementProviding = VerifiedStoreKitEntitlementProvider()
  ) {
    self.monetizationService = monetizationService
    self.privacySettings = privacySettings
    self.isPrivacyLocked = isPrivacyLocked
    self.privacyProtectionEvents = privacyProtectionEvents
    self.privacyLockReason = privacyLockReason
    var restoredMonetizationState = monetizationState
    restoredMonetizationState.entitlement = entitlementProvider.entitlement(
      restoring: monetizationState.entitlement
    )
    self.monetizationState = restoredMonetizationState
    self.monetizationMessage = monetizationMessage
    self.latestProFeatureBlockNotice = latestProFeatureBlockNotice
  }

  public var canUseProtectedWorkbench: Bool {
    !isPrivacyLocked
  }

  public var privacyLockedOperationMessage: String {
    "工作台内容已隐藏，请返回工作台后再继续。"
  }

  public var privacyProtectionStatus: PrivacyProtectionStatus {
    PrivacyProtectionStatus.make(
      settings: privacySettings,
      isLocked: isPrivacyLocked,
      reason: privacyLockReason
    )
  }

  public func privacyProtectionAudit(store: WorkbenchStore) -> PrivacyProtectionAudit {
    PrivacyProtectionAudit.make(
      settings: privacySettings,
      status: privacyProtectionStatus,
      privateDraftCount: store.visibleDrafts.filter(\.isPrivate).count
    )
  }

  public func privacyProtectionEvidencePackage(store: WorkbenchStore) -> PrivacyProtectionEvidencePackage {
    PrivacyProtectionEvidencePackage(
      status: privacyProtectionStatus,
      audit: privacyProtectionAudit(store: store),
      recentEvents: privacyProtectionEvents
    )
  }

  public var proStatusSummary: ProStatusSummary {
    monetizationService.statusSummary(state: monetizationState)
  }

  public var proUpgradePresentation: ProUpgradePresentation {
    .default
  }

  public var proUpgradeRequirements: [ProUpgradeRequirement] {
    monetizationService.upgradeRequirements(state: monetizationState)
  }

  public func proUpgradeRequirement(for feature: PremiumFeature) -> ProUpgradeRequirement {
    monetizationService.upgradeRequirement(for: feature, state: monetizationState)
  }

  public var proMonetizationAuditReport: ProMonetizationAuditReport {
    ProMonetizationAuditReport(
      state: monetizationState,
      requirements: proUpgradeRequirements
    )
  }

  public var proSandboxVerificationSummary: ProSandboxVerificationSummary {
    ProSandboxVerificationSummary.make(
      state: monetizationState,
      requirements: proUpgradeRequirements
    )
  }

  public var proStoreKitReviewEvidencePackage: ProStoreKitReviewEvidencePackage {
    ProStoreKitReviewEvidencePackage(
      statusSummary: proStatusSummary,
      auditReport: proMonetizationAuditReport,
      sandboxSummary: proSandboxVerificationSummary
    )
  }

  public func updatePrivacySettings(_ settings: PrivacyProtectionSettings, store: WorkbenchStore) {
    privacySettings = settings
    recordPrivacyEvent(.settingsUpdated, message: "已更新隐私界面遮罩和私密内容设置。")
    store.save()
  }

  public func privateContentDisplay(for draft: ArticleDraft) -> PrivateContentDisplay {
    guard draft.isPrivate, privacySettings.masksPrivateContent else {
      return PrivateContentDisplay(title: draft.title, summary: draft.summary, isMasked: false)
    }
    return PrivateContentDisplay(title: "私密文章", summary: "内容已遮挡", isMasked: true)
  }

  public func matchesPrivacyProtectedDraftSearch(
    _ draft: ArticleDraft,
    query: String,
    profile: SiteProfile
  ) -> Bool {
    let trimmedQuery = query.trimmedForPublishing
    guard !trimmedQuery.isEmpty else { return true }
    if draft.isPrivate, privacySettings.masksPrivateContent {
      return "私密文章 内容已遮挡".contains(trimmedQuery)
    }
    let haystack = [
      draft.title,
      draft.slug,
      draft.summary,
      draft.tags.joined(separator: " "),
      draft.categories.joined(separator: " "),
      profile.markdownPath(for: draft)
    ].joined(separator: " ").lowercased()
    return haystack.contains(trimmedQuery.lowercased())
  }

  public func accessDecision(for feature: PremiumFeature) -> FeatureAccessDecision {
    monetizationService.accessDecision(for: feature, state: monetizationState)
  }

  public func canStartFeatureUse(_ feature: PremiumFeature) -> FeatureAccessDecision {
    accessDecision(for: feature)
  }

  @discardableResult
  public func consumeFeatureUse(_ feature: PremiumFeature, store: WorkbenchStore) -> FeatureAccessDecision {
    let beforeUsage = monetizationState.freeUsage
    let decision = accessDecision(for: feature)
    let outcome: MonetizationAccessEventOutcome
    let remainingAfter: Int?
    if monetizationState.entitlement.isUnlocked {
      outcome = .allowedProEntitlement
      remainingAfter = nil
    } else if decision.isAllowed {
      outcome = .allowedFreeUse
      remainingAfter = max(0, (decision.remainingFreeUses ?? 0) - 1)
      monetizationState = monetizationService.consuming(feature, state: monetizationState)
    } else {
      outcome = .blockedRequiresPro
      remainingAfter = 0
      latestProFeatureBlockNotice = ProFeatureBlockNotice(
        feature: feature,
        title: decision.title,
        message: decision.message,
        nextStep: "请在 Pro 设置中购买或恢复。"
      )
    }
    var state = monetizationState
    state.recordAccessEvent(
      MonetizationAccessEvent(
        feature: feature,
        outcome: outcome,
        usedFreeUsesBeforeAction: monetizationService.usedFreeUses(for: feature, usage: beforeUsage),
        freeLimit: monetizationService.freeLimit(for: feature),
        remainingFreeUsesAfterAction: remainingAfter,
        message: decision.message
      )
    )
    monetizationState = state
    store.save()
    return decision
  }

  public func remainingFreeUses(for feature: PremiumFeature) -> Int {
    max(0, accessDecision(for: feature).remainingFreeUses ?? 0)
  }

  public func applyVerifiedStoreKitEntitlement(productID: String, store: WorkbenchStore) {
    let now = Date()
    monetizationState.entitlement = ProEntitlementState(
      isUnlocked: true,
      source: .storeKit,
      productID: productID,
      unlockedAt: monetizationState.entitlement.unlockedAt ?? now,
      lastCheckedAt: now
    )
    latestProFeatureBlockNotice = nil
    monetizationMessage = "Pro 已通过 App Store 解锁。"
    store.save()
  }

  func applyEntitlement(from provider: any ProEntitlementProviding, store: WorkbenchStore) {
    monetizationState.entitlement = provider.entitlement(restoring: monetizationState.entitlement)
    latestProFeatureBlockNotice = nil
    store.save()
  }

  public func markProEntitlementCheckCompleted(foundEntitlement: Bool, message: String? = nil, store: WorkbenchStore) {
    var entitlement = monetizationState.entitlement
    entitlement.lastCheckedAt = Date()
    if !foundEntitlement, entitlement.source == .storeKit {
      entitlement = .locked
      entitlement.lastCheckedAt = Date()
    }
    monetizationState.entitlement = entitlement
    if let message {
      monetizationMessage = message
    }
    store.save()
  }

  public func markProRestoreChecked(foundEntitlement: Bool, store: WorkbenchStore) {
    markProEntitlementCheckCompleted(
      foundEntitlement: foundEntitlement,
      message: foundEntitlement ? "已恢复 Pro 购买。" : "没有找到可恢复的 Pro 购买。",
      store: store
    )
  }

  public func lockPrivacy(reason: String? = nil) {
    isPrivacyLocked = true
    privacyLockReason = reason?.nilIfEmpty
  }

  public func unlockPrivacy() {
    isPrivacyLocked = false
    privacyLockReason = nil
  }

  public func recordManualPrivacyMaskShown(reason: String?) {
    recordPrivacyEvent(.manualLock, message: reason?.nilIfEmpty ?? "已手动显示隐私界面遮罩。")
  }

  public func recordPrivacyMaskRemoved() {
    recordPrivacyEvent(.unlocked, message: "已移除隐私界面遮罩。")
  }

  private func recordPrivacyEvent(_ kind: PrivacyProtectionEventKind, message: String) {
    privacyProtectionEvents.insert(PrivacyProtectionEvent(kind: kind, message: message), at: 0)
    privacyProtectionEvents = Array(privacyProtectionEvents.prefix(50))
  }
}
