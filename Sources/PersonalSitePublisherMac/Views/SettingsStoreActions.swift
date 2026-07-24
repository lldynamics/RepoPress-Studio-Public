import PublishingWorkbenchCore

@MainActor
struct SettingsStoreActions {
  let store: WorkbenchStore
  let storeKitProEntitlementCoordinator: StoreKitProEntitlementCoordinator

  func checkRepositoryTokenAccess() async {
    await store.checkRepositoryTokenAccess()
  }

  func lockPrivacyFromSettings() {
    store.lockPrivacy(reason: "已从隐私设置快速隐藏工作台内容。")
  }

  func unlockPrivacyFromSettings() {
    store.unlockPrivacy()
  }

  func updatePrivacySettings(_ settings: PrivacyProtectionSettings) {
    store.updatePrivacySettings(settings)
  }

  func purchasePro() async {
    await storeKitProEntitlementCoordinator.purchasePro(store: store)
  }

  func restorePro() async {
    await storeKitProEntitlementCoordinator.restorePro(store: store)
  }

  func copyProStatusSummary() {
    copyToMonetizationMessage(
      store.proStatusSummary.checklistMarkdown,
      successMessage: "已复制 Pro 状态摘要。"
    )
  }

  private func copyToMonetizationMessage(_ value: String, successMessage: String) {
    ClipboardWriter.copy(value, successMessage: successMessage) { message in
      store.setMonetizationMessage(message)
    }
  }
}
