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

  public var privacyProtectionAudit: PrivacyProtectionAudit {
    privacyMonetizationStore.privacyProtectionAudit(store: self)
  }

  public var privacyProtectionEvidencePackage: PrivacyProtectionEvidencePackage {
    privacyMonetizationStore.privacyProtectionEvidencePackage(store: self)
  }

  public var proStatusSummary: ProStatusSummary {
    privacyMonetizationStore.proStatusSummary
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

  public var proMonetizationAuditReport: ProMonetizationAuditReport {
    privacyMonetizationStore.proMonetizationAuditReport
  }

  public var proSandboxVerificationSummary: ProSandboxVerificationSummary {
    privacyMonetizationStore.proSandboxVerificationSummary
  }

  public var proStoreKitReviewEvidencePackage: ProStoreKitReviewEvidencePackage {
    privacyMonetizationStore.proStoreKitReviewEvidencePackage
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

  public func accessDecision(for feature: PremiumFeature) -> FeatureAccessDecision {
    privacyMonetizationStore.accessDecision(for: feature)
  }

  public func canStartFeatureUse(_ feature: PremiumFeature) -> FeatureAccessDecision {
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
