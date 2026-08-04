import Foundation

extension WorkbenchStore {
  public var canUseProtectedWorkbench: Bool {
    privacyProtectionStore.canUseProtectedWorkbench
  }

  public var quickHideOperationMessage: String {
    privacyProtectionStore.quickHideOperationMessage
  }

  public var privacyProtectionStatus: PrivacyProtectionStatus {
    privacyProtectionStore.privacyProtectionStatus
  }

  public func updatePrivacySettings(_ settings: PrivacyProtectionSettings) {
    privacyProtectionStore.updatePrivacySettings(settings, store: self)
  }

  public func privateContentDisplay(for draft: ArticleDraft) -> PrivateContentDisplay {
    privacyProtectionStore.privateContentDisplay(for: draft)
  }

  public func matchesPrivacyProtectedDraftSearch(
    _ draft: ArticleDraft,
    query: String,
    profile: SiteProfile
  ) -> Bool {
    privacyProtectionStore.matchesPrivacyProtectedDraftSearch(draft, query: query, profile: profile)
  }

  public func privacyProtectedSearchDraft(for draft: ArticleDraft) -> ArticleDraft {
    privacyProtectionStore.privacyProtectedSearchDraft(for: draft)
  }
}
