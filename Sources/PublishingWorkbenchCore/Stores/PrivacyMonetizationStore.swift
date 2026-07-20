import Combine
import Foundation

@MainActor
public final class PrivacyMonetizationStore: ObservableObject {
  private let monetizationService: MonetizationService

  @Published public internal(set) var privacySettings: PrivacyProtectionSettings
  @Published public internal(set) var isPrivacyLocked: Bool
  @Published public internal(set) var privacyLockReason: String?
  @Published public internal(set) var monetizationState: MonetizationState
  @Published public internal(set) var monetizationMessage: String?
  @Published public internal(set) var latestProFeatureBlockNotice: ProFeatureBlockNotice?

  init(
    privacySettings: PrivacyProtectionSettings = .default,
    isPrivacyLocked: Bool = false,
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
    self.privacyLockReason = privacyLockReason
    var restoredMonetizationState = monetizationState
    restoredMonetizationState.entitlement = entitlementProvider.entitlement(
      restoring: monetizationState.entitlement
    )
    self.monetizationState = monetizationService.normalizedState(restoredMonetizationState)
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

  public var proStatusSummary: ProStatusSummary {
    monetizationService.statusSummary(state: monetizationState)
  }

  public var currentFreePlanUsage: FreePlanUsage {
    monetizationService.normalizedFreeUsage(monetizationState.freeUsage)
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

  public func updatePrivacySettings(_ settings: PrivacyProtectionSettings, store: WorkbenchStore) {
    privacySettings = settings.normalized
    store.save()
  }

  public func privateContentDisplay(for draft: ArticleDraft) -> PrivateContentDisplay {
    guard draft.isPrivate, privacySettings.masksPrivateContent else {
      return PrivateContentDisplay(title: draft.title, summary: draft.summary, isMasked: false)
    }
    return PrivateContentDisplay(title: draft.title, summary: "内容已遮挡", isMasked: true)
  }

  public func matchesPrivacyProtectedDraftSearch(
    _ draft: ArticleDraft,
    query: String,
    profile: SiteProfile
  ) -> Bool {
    let trimmedQuery = query.trimmedForPublishing
    guard !trimmedQuery.isEmpty else { return true }
    if draft.isPrivate, privacySettings.masksPrivateContent {
      let protectedHaystack = [draft.title, "私密文章", "内容已遮挡"]
        .joined(separator: " ")
        .lowercased()
      return protectedHaystack.contains(trimmedQuery.lowercased())
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

  public func privacyProtectedSearchDraft(for draft: ArticleDraft) -> ArticleDraft {
    guard draft.isPrivate, privacySettings.masksPrivateContent else {
      return draft
    }
    var protectedDraft = draft
    protectedDraft.slug = ""
    protectedDraft.summary = ""
    protectedDraft.bodyMarkdown = ""
    protectedDraft.tags = []
    protectedDraft.categories = []
    protectedDraft.authors = []
    protectedDraft.repositoryPath = nil
    return protectedDraft
  }

  public func accessDecision(for feature: PremiumFeature) -> FeatureAccessDecision {
    monetizationService.accessDecision(for: feature, state: monetizationState)
  }

  public func canStartFeatureUse(_ feature: PremiumFeature) -> FeatureAccessDecision {
    accessDecision(for: feature)
  }

  @discardableResult
  public func refreshDailyFreeUsageIfNeeded(
    now: Date = Date(),
    calendar: Calendar = .current
  ) -> Bool {
    let normalizedUsage = monetizationService.normalizedFreeUsage(
      monetizationState.freeUsage,
      at: now,
      calendar: calendar
    )
    guard normalizedUsage != monetizationState.freeUsage else { return false }

    monetizationState.freeUsage = normalizedUsage
    latestProFeatureBlockNotice = nil
    return true
  }

  @discardableResult
  public func consumeFeatureUse(_ feature: PremiumFeature, store: WorkbenchStore) -> FeatureAccessDecision {
    refreshDailyFreeUsageIfNeeded()
    let decision = accessDecision(for: feature)
    if monetizationState.entitlement.isUnlocked {
    } else if decision.isAllowed {
      monetizationState = monetizationService.consuming(feature, state: monetizationState)
    } else {
      latestProFeatureBlockNotice = ProFeatureBlockNotice(
        feature: feature,
        title: decision.title,
        message: decision.message,
        nextStep: "请在 Pro 设置中购买或恢复。"
      )
    }
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

}
