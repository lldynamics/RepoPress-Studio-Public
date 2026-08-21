import PublishingWorkbenchCore

@MainActor
struct SettingsStoreActions {
  let store: WorkbenchStore

  func checkRepositoryTokenAccess() async {
    await store.checkRepositoryTokenAccess()
  }

  func quickHideFromSettings() {
    store.activateQuickHide(reason: "已从隐私设置快速隐藏工作台内容。")
  }

  func updatePrivacySettings(_ settings: PrivacyProtectionSettings) {
    store.updatePrivacySettings(settings)
  }

}
