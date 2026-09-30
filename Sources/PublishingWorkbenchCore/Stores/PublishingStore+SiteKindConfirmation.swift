extension PublishingStore {
  @discardableResult
  public func applySiteKindDefaults(
    _ siteKind: SiteKind,
    expectedTarget: SiteOperationConfirmationTarget? = nil,
    store: WorkbenchStore
  ) -> Bool {
    let target = expectedTarget ?? SiteOperationConfirmationTarget(profile: store.activeProfile)
    guard target.matches(store.activeProfile) else {
      setPublishActionMessage(CoreL10n.text("站点或配置已变化，请重新预览站点类型变化。"), status: .warning)
      return false
    }
    var profile = target.profile
    profile.applyPublishingDefaults(for: siteKind)
    store.updateActiveProfile(profile)
    store.runPreflight()
    store.save()
    return true
  }
}
