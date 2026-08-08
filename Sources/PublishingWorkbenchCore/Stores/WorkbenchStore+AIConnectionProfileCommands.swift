import Foundation

extension WorkbenchStore {
  public func aiConnectionProfile(for id: UUID) -> AIConnectionProfile? {
    aiConnectionProfiles.first { $0.id == id }
  }

  /// Resolves the reusable connection selected by a site, falling back to the
  /// legacy inline config while an older snapshot is being migrated.
  public func aiConnectionProfile(for siteProfile: SiteProfile) -> AIConnectionProfile {
    if let connectionID = siteProfile.aiConnectionProfileID,
       let connection = aiConnectionProfiles.first(where: { $0.id == connectionID }) {
      return connection
    }
    return AIConnectionProfile(
      id: siteProfile.aiConnectionProfileID ?? UUID(),
      name: siteProfile.aiProviderConfig.normalizedDisplayName,
      config: siteProfile.aiProviderConfig
    )
  }

  public func aiProviderConfig(for siteProfile: SiteProfile) -> AIProviderConfig {
    aiConnectionProfile(for: siteProfile).config
  }

  public var activeAIConnectionProfile: AIConnectionProfile {
    aiConnectionProfile(for: activeProfile)
  }

  @discardableResult
  public func createAIConnectionProfile(
    named name: String,
    preset: AIProviderPreset
  ) -> AIConnectionProfile {
    let profile = AIConnectionProfile.template(named: name, preset: preset)
    aiConnectionProfiles.append(profile)
    save()
    return profile
  }

  @discardableResult
  public func updateAIConnectionProfile(_ connection: AIConnectionProfile) -> Bool {
    guard let index = aiConnectionProfiles.firstIndex(where: { $0.id == connection.id }) else {
      return false
    }
    var normalized = connection
    normalized.name = normalized.name.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
      ?? normalized.config.normalizedDisplayName
    guard invalidateAIConnectionProfileCredentialsIfNeeded(
      from: aiConnectionProfiles[index].config,
      to: normalized.config,
      connectionProfileID: normalized.id
    ) else { return false }
    aiConnectionProfiles[index] = normalized

    var updatedSites = profiles
    for siteIndex in updatedSites.indices
    where updatedSites[siteIndex].aiConnectionProfileID == normalized.id {
      // Keep the old inline field synchronized for compatibility with older
      // exports and code paths that do not have a WorkbenchStore resolver.
      updatedSites[siteIndex].aiProviderConfig = normalized.config
    }
    setProfiles(updatedSites)
    save()
    refreshAIKeyAvailability()
    return true
  }

  @discardableResult
  public func selectAIConnectionProfile(_ connectionID: UUID) -> Bool {
    guard let connection = aiConnectionProfiles.first(where: { $0.id == connectionID }) else {
      return false
    }
    let previousProfile = activeProfile
    guard previousProfile.aiConnectionProfileID != connectionID else { return true }
    if previousProfile.aiProviderConfig.chatCompletionsURL != nil {
      do {
        try keychainTokenStore.deleteLegacyAIToken(for: previousProfile)
      } catch KeychainTokenStoreError.invalidCredentialOrigin(_) {
        // No origin-bound legacy credential can exist for an address that the
        // Keychain store would never have accepted.
      } catch {
        setAIActionMessage(CoreL10n.format(
          "AI 连接未切换：旧版 API Key 清理失败。请检查 Keychain 权限后重试。%@",
          error.localizedDescription
        ))
        return false
      }
    }
    var updatedProfile = activeProfile
    updatedProfile.aiConnectionProfileID = connection.id
    updatedProfile.aiProviderConfig = connection.config
    updateActiveProfile(updatedProfile)
    save()
    refreshAIKeyAvailability()
    return true
  }

  @discardableResult
  public func deleteAIConnectionProfile(_ connectionID: UUID) -> Bool {
    guard canDeleteAIConnectionProfile(connectionID) else {
      if aiConversations.contains(where: {
        $0.scope == .general && $0.connectionProfileID == connectionID
      }) {
        setAIActionMessage(
          CoreL10n.text("AI 连接仍被通用对话绑定，请先为这些对话重新绑定后再删除。")
        )
      }
      return false
    }

    do {
      try keychainTokenStore.deleteAIToken(forConnectionProfileID: connectionID)
    } catch {
      var message = CoreL10n.format(
        "AI 连接未删除：关联的 API Key 删除失败。请检查 Keychain 权限后重试。%@",
        error.localizedDescription
      )
      if let keychainError = error as? KeychainTokenStoreError,
         let recoveryHint = keychainError.recoveryHint {
        message += " " + recoveryHint
      }
      setAIActionMessage(message)
      return false
    }

    aiConnectionProfiles.removeAll { $0.id == connectionID }
    save()
    setAIActionMessage(CoreL10n.text("AI 连接及其 API Key 已删除。"))
    return true
  }

  public func canDeleteAIConnectionProfile(_ connectionID: UUID) -> Bool {
    aiConnectionProfiles.count > 1
      && !profiles.contains(where: { $0.aiConnectionProfileID == connectionID })
      && !aiConversations.contains {
        $0.scope == .general && $0.connectionProfileID == connectionID
      }
  }

  /// API credentials are bound to a provider and destination. Model-only
  /// changes keep the same boundary, while a preset, scheme, host, port or path
  /// change must remove the old credential before the new config is committed.
  @discardableResult
  func invalidateAIConnectionProfileCredentialsIfNeeded(
    from previousConfig: AIProviderConfig,
    to updatedConfig: AIProviderConfig,
    connectionProfileID: UUID
  ) -> Bool {
    guard previousConfig.dataSharingConsentIdentifier
      != updatedConfig.dataSharingConsentIdentifier
    else {
      return true
    }

    let isActiveConnection = activeAIConnectionProfile.id == connectionProfileID
    do {
      for profile in profiles
      where profile.aiConnectionProfileID == connectionProfileID
        && profile.aiProviderConfig.chatCompletionsURL != nil {
        // A blank or invalid legacy endpoint could never have produced an
        // origin-bound credential. Skip it so a newly empty configuration can
        // be configured for the first time without turning cleanup into an
        // access failure.
        try keychainTokenStore.deleteLegacyAIToken(for: profile)
      }
      // Keep the authoritative shared credential until every best-effort
      // legacy fallback has been removed. If legacy cleanup fails, cancelling
      // the config edit must not also destroy the still-valid shared key.
      try keychainTokenStore.deleteAIToken(
        forConnectionProfileID: connectionProfileID
      )
      if isActiveConnection {
        refreshAIKeyAvailability()
        setAIActionMessage(CoreL10n.text("服务商或 API 地址已更改，旧 API Key 已移除，请重新保存。"))
        setAIChatMessage(CoreL10n.text("服务商或 API 地址已更改，请重新保存 API Key 后再发送消息。"))
      }
      return true
    } catch {
      if isActiveConnection {
        setAITokenAvailability(KeychainTokenAvailability(accessFailure: error))
      }
      setAIActionMessage(CoreL10n.format(
        "API 地址未更改：旧 API Key 删除失败，请检查 Keychain 权限后重试。%@",
        error.localizedDescription
      ))
      setAIChatMessage(CoreL10n.text("为防止旧 API Key 发送到新地址，本次 AI 连接修改已取消。"))
      return false
    }
  }
}
