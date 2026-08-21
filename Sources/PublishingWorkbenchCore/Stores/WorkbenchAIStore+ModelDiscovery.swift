import Foundation

extension WorkbenchAIStore {
  /// Resolves the credential only after the UI's request is proven to still
  /// target the selected connection profile. In particular, an unapplied Base
  /// URL cannot cause a key saved for the old endpoint to leave the process.
  public func discoverAIModels(
    forConnectionProfileID connectionProfileID: UUID,
    requestedConfig: AIProviderConfig,
    forceRefresh: Bool = true
  ) async throws -> [AIModelDescriptor] {
    try await discoverAIModels(
      forConnectionProfileID: connectionProfileID,
      requestedConfig: requestedConfig,
      service: AIModelDiscoveryService(),
      forceRefresh: forceRefresh
    )
  }

  /// Injectable overload used by Core tests to prove identity rejection
  /// without creating a real URLSession or contacting a provider.
  func discoverAIModels(
    forConnectionProfileID connectionProfileID: UUID,
    requestedConfig: AIProviderConfig,
    service: AIModelDiscoveryService,
    forceRefresh: Bool = true
  ) async throws -> [AIModelDescriptor] {
    guard let currentConnection = store.aiConnectionProfile(for: connectionProfileID),
      store.activeAIConnectionProfile.id == connectionProfileID,
      currentConnection.config.dataSharingConsentIdentifier
        == requestedConfig.dataSharingConsentIdentifier
    else {
      throw AIModelDiscoveryError.configurationChanged
    }

    // The settings view deliberately reconstructs this request from its
    // editable fields and therefore does not carry advanced settings such as
    // the profile's proxy URL. Keep the requested config only as an identity
    // claim; all transport-sensitive values must come from the applied
    // connection profile that also owns the credential.
    let boundConfig = currentConnection.config
    let apiKey = try aiChatAvailableAPIKey(for: currentConnection)
    try Task.checkCancellation()
    let models = try await service.discoverModels(
      for: boundConfig,
      apiKey: apiKey,
      forceRefresh: forceRefresh
    )
    try Task.checkCancellation()
    guard let latestConnection = store.aiConnectionProfile(for: connectionProfileID),
      store.activeAIConnectionProfile.id == connectionProfileID,
      latestConnection.config.dataSharingConsentIdentifier
        == boundConfig.dataSharingConsentIdentifier,
      latestConnection.config == boundConfig
    else {
      throw AIModelDiscoveryError.configurationChanged
    }
    guard aiDataSharingConsentStore.presentation(for: boundConfig).isGranted else {
      throw AIModelDiscoveryError.authorizationChanged
    }
    return models
  }
}
