import Foundation

extension WorkbenchAIStore {
  public var aiCredentialStorageMode: AICredentialStorageMode {
    aiCredentialStore.storageMode
  }

  public func setAICredentialStorageMode(_ mode: AICredentialStorageMode) {
    guard mode != aiCredentialStore.storageMode else { return }
    aiCredentialStore.setStorageMode(mode)
    if activeStreamingAuthorization?.config.requiresAPIKey == true {
      cancelStreamingAuthorization()
    }
    cancelNonStreamingAuthorization(requiresAPIKeyOnly: true)
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
