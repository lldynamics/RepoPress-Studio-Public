import Foundation

extension WorkbenchStore {
  public var canUseProtectedWorkbench: Bool {
    privacyMonetizationStore.canUseProtectedWorkbench
  }

  public var privacyLockedOperationMessage: String {
    privacyMonetizationStore.privacyLockedOperationMessage
  }

  public var privacyProtectionStatus: PrivacyProtectionStatus {
    privacyMonetizationStore.privacyProtectionStatus
  }

  public var proStatusSummary: ProStatusSummary {
    privacyMonetizationStore.proStatusSummary
  }

  public var currentFreePlanUsage: FreePlanUsage {
    privacyMonetizationStore.currentFreePlanUsage
  }

  public var proUpgradePresentation: ProUpgradePresentation {
    privacyMonetizationStore.proUpgradePresentation
  }

  public var proUpgradeRequirements: [ProUpgradeRequirement] {
    privacyMonetizationStore.proUpgradeRequirements
  }

  public func proUpgradeRequirement(for feature: PremiumFeature) -> ProUpgradeRequirement {
    privacyMonetizationStore.proUpgradeRequirement(for: feature)
  }

  public func updatePrivacySettings(_ settings: PrivacyProtectionSettings) {
    privacyMonetizationStore.updatePrivacySettings(settings, store: self)
  }

  public func privateContentDisplay(for draft: ArticleDraft) -> PrivateContentDisplay {
    privacyMonetizationStore.privateContentDisplay(for: draft)
  }

  public func matchesPrivacyProtectedDraftSearch(
    _ draft: ArticleDraft,
    query: String,
    profile: SiteProfile
  ) -> Bool {
    privacyMonetizationStore.matchesPrivacyProtectedDraftSearch(draft, query: query, profile: profile)
  }

  public func privacyProtectedSearchDraft(for draft: ArticleDraft) -> ArticleDraft {
    privacyMonetizationStore.privacyProtectedSearchDraft(for: draft)
  }

  public func accessDecision(for feature: PremiumFeature) -> FeatureAccessDecision {
    privacyMonetizationStore.accessDecision(for: feature)
  }

  public func canStartFeatureUse(_ feature: PremiumFeature) -> FeatureAccessDecision {
    refreshDailyFreeUsageIfNeeded()
    let decision = privacyMonetizationStore.canStartFeatureUse(feature)
    if !decision.isAllowed {
      privacyMonetizationStore.latestProFeatureBlockNotice = ProFeatureBlockNotice(
        feature: feature,
        title: decision.title,
        message: decision.message,
        nextStep: "请在 Pro 设置中购买或恢复。"
      )
      privacyMonetizationStore.monetizationMessage = decision.message
      save()
    }
    return decision
  }

  @discardableResult
  public func consumeFeatureUse(_ feature: PremiumFeature) -> FeatureAccessDecision {
    privacyMonetizationStore.consumeFeatureUse(feature, store: self)
  }

  public func remainingFreeUses(for feature: PremiumFeature) -> Int {
    privacyMonetizationStore.remainingFreeUses(for: feature)
  }

  @discardableResult
  public func refreshDailyFreeUsageIfNeeded(
    now: Date = Date(),
    calendar: Calendar = .current
  ) -> Bool {
    let didReset = privacyMonetizationStore.refreshDailyFreeUsageIfNeeded(
      now: now,
      calendar: calendar
    )
    if didReset {
      save()
    }
    return didReset
  }

  public func applyVerifiedStoreKitEntitlement(productID: String) {
    privacyMonetizationStore.applyVerifiedStoreKitEntitlement(productID: productID, store: self)
  }

  func applyProEntitlement(from provider: any ProEntitlementProviding) {
    privacyMonetizationStore.applyEntitlement(from: provider, store: self)
  }

  public func markProEntitlementCheckCompleted(
    foundEntitlement: Bool,
    message: String? = nil
  ) {
    privacyMonetizationStore.markProEntitlementCheckCompleted(
      foundEntitlement: foundEntitlement,
      message: message,
      store: self
    )
  }

  public func markProRestoreChecked(foundEntitlement: Bool) {
    privacyMonetizationStore.markProRestoreChecked(foundEntitlement: foundEntitlement, store: self)
  }
}
