import Foundation

extension WorkbenchAIStore {
  public var isRemoteAIEnabled: Bool {
    aiDataSharingConsentStore.isRemoteAIEnabled
  }

  public func setRemoteAIEnabled(_ enabled: Bool) {
    let changed = aiDataSharingConsentStore.isRemoteAIEnabled != enabled
    aiDataSharingConsentStore.setRemoteAIEnabled(enabled)
    guard changed else { return }
    if !enabled {
      cancelStreamingAuthorization(remoteOnly: true)
      cancelNonStreamingAuthorization(remoteOnly: true)
    }
    objectWillChange.send()
    let message =
      enabled
      ? "已开启远程 AI；原有逐服务授权会恢复生效。"
      : "已关闭远程 AI。逐服务授权会保留，重新开启后恢复；本地 AI 仍可用。"
    aiActionMessage = message
    aiChatMessage = message
  }

  public func grantAIDataSharingConsent() {
    let config = store.aiProviderConfig(for: store.activeProfile)
    grantAIDataSharingConsent(for: config)
  }

  public func grantAIDataSharingConsent(
    for config: AIProviderConfig,
    enablingRemoteAI: Bool = false,
    codexAccountStatus: CodexAppServerAccountStatus? = nil
  ) {
    if enablingRemoteAI, !config.isLocalEndpoint, !config.dataSharingDestination.isEmpty {
      aiDataSharingConsentStore.setRemoteAIEnabled(true)
    }
    let granted = aiDataSharingConsentStore.grant(
      for: config,
      codexAccountStatus: codexAccountStatus
    )
    let presentation = aiDataSharingConsentStore.presentation(
      for: config,
      codexAccountStatus: codexAccountStatus
    )
    if config.isLocalEndpoint {
      aiActionMessage = "当前为本地 AI 服务，内容不会发送给第三方服务商。"
    } else if config.dataSharingDestination.isEmpty {
      aiActionMessage = "尚未配置 API 基础地址，授权暂不生效。"
    } else if config.usesCodexAppServer && !granted {
      aiActionMessage = "请先登录 ChatGPT，并在当前账户下重新同意内容发送。"
    } else if !presentation.isRemoteAIEnabled {
      aiActionMessage = "已保留此服务的逐项授权，但远程 AI 总闸已关闭；当前不会发送远程请求。"
    } else {
      aiActionMessage =
        "已允许向 \(config.normalizedDisplayName)（\(config.dataSharingDestination)）发送内容。"
    }
  }

  /// Explicit Codex consent is bound to the account status obtained by the
  /// account section immediately after login. A status-less call remains
  /// fail-closed and cannot upgrade a legacy grant.
  public func grantCodexAIDataSharingConsent(
    for accountStatus: CodexAppServerAccountStatus
  ) {
    let config = store.aiProviderConfig(for: store.activeProfile)
    grantAIDataSharingConsent(
      for: config,
      enablingRemoteAI: true,
      codexAccountStatus: accountStatus
    )
  }

  public func revokeAIDataSharingConsent(connectionProfileID: UUID? = nil) {
    let config: AIProviderConfig
    if let connectionProfileID {
      guard let connection = store.aiConnectionProfile(for: connectionProfileID) else { return }
      config = connection.config
    } else {
      config = store.aiProviderConfig(for: store.activeProfile)
    }
    aiDataSharingConsentStore.revoke(for: config)
    cancelStreamingAuthorization(destination: config.dataSharingDestination)
    cancelNonStreamingAuthorization(revokedConfig: config)
    aiActionMessage = "已撤销 \(config.normalizedDisplayName) 的内容发送授权。"
  }
}
