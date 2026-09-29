import Foundation
import PublishingAICore

extension WorkbenchAIStore {
  // A manager selection is an explicit connection identity, never a site binding.
  private func settingsConnection(for id: UUID?) -> AIConnectionProfile? {
    if let id { return store.aiConnectionProfile(for: id) }
    return store.activeAIConnectionProfile
  }

  private func settingsLegacyProfile(for connection: AIConnectionProfile) -> SiteProfile? {
    guard connection.canUseLegacyCredentials else { return nil }
    let candidates = store.profiles.filter {
      $0.aiConnectionProfileID == connection.id
        && $0.aiProviderConfig.dataSharingConsentIdentifier
          == connection.config.dataSharingConsentIdentifier
    }
    if let active = candidates.first(where: { $0.id == store.activeProfileID }) {
      return active
    }
    // Only an unambiguous historical owner may supply a legacy credential.
    // Shared connections with multiple different site identities require a profile key.
    return candidates.count == 1 ? candidates.first : nil
  }

  func settingsAPIKey(for connection: AIConnectionProfile) throws -> String? {
    if let profile = settingsLegacyProfile(for: connection) {
      return try aiChatAvailableAPIKey(for: profile)
    }
    return try aiChatAvailableAPIKey(for: connection)
  }

  public func refreshAIKeyAvailability() {
    refreshAIKeyAvailability(for: store.activeProfile)
  }

  public func aiKeyAvailability(
    forConnectionProfileID connectionProfileID: UUID
  ) -> KeychainTokenAvailability {
    guard let connection = store.aiConnectionProfile(for: connectionProfileID),
      connection.config.requiresAPIKey,
      !connection.config.normalizedBaseURL.isEmpty
    else {
      return KeychainTokenAvailability(hasToken: false)
    }
    do {
      return try aiCredentialStore.availability(
        forConnectionProfileID: connectionProfileID,
        legacyProfile: settingsLegacyProfile(for: connection)
      )
    } catch {
      return KeychainTokenAvailability(accessFailure: error)
    }
  }

  func refreshAIKeyAvailability(for profile: SiteProfile) {
    let connection = store.aiConnectionProfile(for: profile)
    guard connection.config.requiresAPIKey else {
      aiTokenAvailability = KeychainTokenAvailability(hasToken: false)
      return
    }
    guard !connection.config.normalizedBaseURL.isEmpty else {
      aiTokenAvailability = KeychainTokenAvailability(hasToken: false)
      return
    }
    do {
      aiTokenAvailability = try aiCredentialStore.availability(
        forConnectionProfileID: connection.id,
        legacyProfile: connection.canUseLegacyCredentials ? profile : nil
      )
    } catch {
      aiTokenAvailability = KeychainTokenAvailability(accessFailure: error)
    }
  }

  @discardableResult
  public func saveAIAPIKey(
    _ token: String, forConnectionProfileID connectionID: UUID? = nil
  ) -> Bool {
    guard let connection = settingsConnection(for: connectionID) else { return false }
    guard !connection.config.normalizedBaseURL.isEmpty else {
      aiActionMessage = CoreL10n.text("API Base URL 尚未配置。")
      return false
    }
    do {
      try aiCredentialStore.saveToken(
        token.trimmedForPublishing,
        forConnectionProfileID: connection.id,
        legacyProfile: settingsLegacyProfile(for: connection)
      )
      cancelStreamingAuthorization(connectionID: connection.id)
      cancelNonStreamingAuthorization(connectionID: connection.id)
      refreshAIKeyAvailability()
      aiActionMessage = CoreL10n.format(
        "AI API Key 已保存到 %@。",
        credentialStorageModeName(aiCredentialStore.storageMode)
      )
      aiChatMessage = "AI API Key 已就绪，可以发送消息。"
      return true
    } catch {
      aiActionMessage = aiCredentialFailureMessage(action: "保存", error: error)
      return false
    }
  }

  public func deleteAIAPIKey(forConnectionProfileID connectionID: UUID? = nil) {
    guard let connection = settingsConnection(for: connectionID) else { return }
    do {
      try aiCredentialStore.deleteToken(
        forConnectionProfileID: connection.id,
        legacyProfiles: settingsLegacyProfile(for: connection).map { [$0] } ?? []
      )
      refreshAIKeyAvailability()
      cancelStreamingAuthorization(connectionID: connection.id)
      cancelNonStreamingAuthorization(connectionID: connection.id)
      aiActionMessage = "AI API Key 已删除。"
      aiChatMessage = "AI API Key 已删除，请重新配置后再发送消息。"
    } catch {
      aiActionMessage = aiCredentialFailureMessage(action: "删除", error: error)
    }
  }

  private func aiCredentialFailureMessage(action: String, error: Error) -> String {
    var message = "AI API Key \(action)失败：\(error.localizedDescription)"
    if let keychainError = error as? KeychainTokenStoreError,
      let recoveryHint = keychainError.recoveryHint
    {
      message += " \(recoveryHint)"
    }
    return message
  }

  public func testAIConnection(
    connectionProfileID: UUID? = nil,
    probeCapabilities: Set<AIProviderCapabilityProbeKind> = []
  ) async -> AIConnectionTestReport? {
    guard !Task.isCancelled,
      let connection = settingsConnection(for: connectionProfileID)
    else { return nil }
    let lane = AIGenerationLane.connectionTest
    let generation = beginAIRequest(lane, showsActionLoading: true)
    defer { finishAIRequest(lane, generation: generation) }
    let config = connection.config
    aiRequestContextChecks[lane] = { [weak self] in
      guard let self else { return false }
      return self.settingsConnection(for: connectionProfileID)?.id == connection.id
        && self.settingsConnection(for: connectionProfileID)?.config == config
    }
    let configKey = AIProviderCapabilityCacheKey(config: config)
    let consent = aiDataSharingConsentStore.presentation(for: config)
    if config.usesCodexAppServer {
      do {
        try await awaitAIRequest(lane, generation: generation) { [self] in
          try await CodexAppServerRequestAuthorizer(
            consentStore: aiDataSharingConsentStore,
            accountStatusProvider: CodexAppServerClient.shared
          ).authorize(config: config)
        }
      } catch {
        guard !(error is CancellationError), canPresentAIRequest(lane, generation: generation)
        else { return nil }
        aiActionMessage = error.localizedDescription
        return nil
      }
    } else if !consent.isGranted {
      aiActionMessage = "请先明确同意向 \(consent.destination) 发送 AI 连接测试数据。"
      return nil
    }
    do {
      try checkAIRequest(lane, generation: generation)
      let token = try settingsAPIKey(for: connection)
      let report: AIConnectionTestReport
      if config.usesCodexAppServer {
        // WorkbenchStore's connection-test service is constructed before the
        // Workbench consent store is available and therefore owns a default
        // client. Route Codex's test through the already-bound publishing
        // client so this prompt uses the same account authorization dependency
        // as every other AI request.
        report = try await awaitAIRequest(lane, generation: generation) { [self] in
          try await testCodexConnection(
            config: config,
            probeCapabilities: probeCapabilities
          )
        }
      } else {
        report = try await awaitAIRequest(lane, generation: generation) { [self] in
          try await aiConnectionTestService.testConnection(
            config: config,
            apiKey: token,
            probeCapabilities: probeCapabilities
          )
        }
      }
      try checkAIRequest(lane, generation: generation)
      guard settingsConnection(for: connectionProfileID)?.id == connection.id,
        settingsConnection(for: connectionProfileID)?.config == config
      else { return nil }
      let presentsReport = canPresentAIRequest(lane, generation: generation)

      if let capabilityProbeReport = report.capabilityProbeReport,
        let currentConnection = settingsConnection(for: connectionProfileID)
      {
        let hasNotDrifted =
          currentConnection.id == connection.id
          && currentConnection.config == config
          && AIProviderCapabilityCacheKey(config: currentConnection.config) == configKey
          && capabilityProbeReport.key == configKey
        if hasNotDrifted {
          let updatedConfig = capabilityProbeReport.applying(
            to: currentConnection.config,
            at: Date()
          )
          if updatedConfig != currentConnection.config {
            var updatedConnection = currentConnection
            updatedConnection.config = updatedConfig
            // Keep persistence and the legacy site-owned mirror on the
            // existing connection-profile update path. If identity drifted,
            // this branch is never reached and no evidence is written.
            _ = store.updateAIConnectionProfile(updatedConnection)
          }
        }
      }
      refreshAIKeyAvailability()
      if presentsReport {
        aiActionMessage = report.headline
        aiChatMessage = "AI 连接正常，可以发送消息。"
      }
      return report
    } catch {
      guard !(error is CancellationError), canPresentAIRequest(lane, generation: generation) else {
        return nil
      }
      store.setAIActionFailureMessage(
        CoreL10n.format("AI 连接测试失败：%@", error.localizedDescription)
      )
      return nil
    }
  }

  private func testCodexConnection(
    config: AIProviderConfig,
    probeCapabilities: Set<AIProviderCapabilityProbeKind>
  ) async throws -> AIConnectionTestReport {
    guard let endpoint = config.chatCompletionsURL else {
      throw AIConnectionTestError.invalidBaseURL(config.normalizedBaseURL)
    }
    let result = try await aiPublishingAssistantService.client.complete(
      request: AIChatCompletionRequest(
        model: config.normalizedModel,
        messages: [
          AIChatMessage(role: "system", content: "Return only OK."),
          AIChatMessage(role: "user", content: "ping"),
        ],
        temperature: 0,
        maximumOutputTokens: 8
      ),
      config: config,
      apiKey: nil,
      purpose: .connectionTest
    )
    let capabilityProbeReport: AIProviderCapabilityProbeReport?
    if probeCapabilities.isEmpty {
      capabilityProbeReport = nil
    } else {
      capabilityProbeReport = try await AIProviderCapabilityProbeService(
        client: aiPublishingAssistantService.client
      ).probe(
        config: config,
        apiKey: nil,
        capabilities: probeCapabilities,
        forceRefresh: false,
        existingChatProof: probeCapabilities.contains(.chat)
          ? AIProviderCapabilityChatProbeProof(
            key: AIProviderCapabilityCacheKey(config: config),
            result: result
          )
          : nil
      )
    }
    return AIConnectionTestReport(
      providerName: config.normalizedDisplayName,
      model: config.normalizedModel,
      endpoint: endpoint,
      responsePreview: result.content,
      capabilityProbeReport: capabilityProbeReport
    )
  }

}
