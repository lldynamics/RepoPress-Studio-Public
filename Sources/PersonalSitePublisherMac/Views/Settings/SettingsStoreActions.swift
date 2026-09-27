import PublishingWorkbenchCore

@MainActor
struct SettingsStoreActions {
  let store: WorkbenchStore

  func checkRepositoryTokenAccess() async {
    await store.checkRepositoryTokenAccess()
  }

  func updatePrivacySettings(_ settings: PrivacyProtectionSettings) {
    store.updatePrivacySettings(settings)
  }

}
