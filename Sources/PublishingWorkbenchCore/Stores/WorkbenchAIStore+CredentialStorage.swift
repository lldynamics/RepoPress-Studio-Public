import Foundation

extension WorkbenchAIStore {
  public var aiCredentialStorageMode: AICredentialStorageMode {
    aiCredentialStorageMode(forConnectionProfileID: store.activeAIConnectionProfile.id)
  }

  public func aiCredentialStorageMode(forConnectionProfileID id: UUID) -> AICredentialStorageMode {
    aiCredentialStore.storageMode(forConnectionProfileID: id)
  }

  public func setAICredentialStorageMode(_ mode: AICredentialStorageMode) {
    setAICredentialStorageMode(mode, connectionProfileID: store.activeAIConnectionProfile.id)
  }

  public func setAICredentialStorageMode(
    _ mode: AICredentialStorageMode, connectionProfileID id: UUID
  ) {
    guard store.aiConnectionProfile(for: id) != nil,
      mode != aiCredentialStore.storageMode(forConnectionProfileID: id)
    else { return }
    aiCredentialStore.setStorageMode(mode, forConnectionProfileID: id)
    cancelNonStreamingAuthorization(connectionID: id, requiresAPIKeyOnly: true)
    refreshAIKeyAvailability()
    aiActionMessage = CoreL10n.format(
      "API Key 保存位置已切换为 %@。不同保存位置之间不会自动复制或删除 Key。",
      credentialStorageModeName(mode)
    )
  }

  func credentialStorageModeName(_ mode: AICredentialStorageMode) -> String {
    switch mode {
    case .localFile:
      return CoreL10n.text("本地配置文件")
    case .keychain:
      return "Keychain"
    case .session:
      return CoreL10n.text("本次会话")
    }
  }

}
