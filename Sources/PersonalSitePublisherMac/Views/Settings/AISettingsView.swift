import PublishingAICore
import PublishingWorkbenchCore
import SwiftUI

struct AISettingsView: View {
  let activeProfileBinding: Binding<SiteProfile>
  let connectionProfiles: [AIConnectionProfile]
  let referencingSiteProfiles: [SiteProfile]
  let activeConnectionProfileID: UUID
  let updateConnectionProfile: (AIConnectionProfile) -> Bool
  let createConnectionProfile: (String, AIProviderPreset) -> AIConnectionProfile
  let duplicateConnectionProfile: (UUID) -> AIConnectionProfile?
  let currentActionMessage: () -> String?
  let deleteConnectionProfile: (UUID) -> Void
  let deletableConnectionProfiles: [AIConnectionProfile]
  let credentialStorageMode: AICredentialStorageMode
  let tokenAvailability: KeychainTokenAvailability
  let isActionRunning: Bool
  let actionMessage: String?
  let dataSharingConsent: AIDataSharingConsentPresentation
  let shouldFocusAPIKey: Bool
  let healthNavigationRequestID: UUID
  let navigationDestination: SettingsDestination?
  let navigationRequestID: UUID
  let saveAPIKey: (String) -> Bool
  let deleteAPIKey: () -> Void
  let refreshKeyAvailability: () -> Void
  let setCredentialStorageMode: (AICredentialStorageMode) -> Void
  let testConnection: (Set<AIProviderCapabilityProbeKind>) async -> AIConnectionTestReport?
  let discoverModels: (UUID, AIProviderConfig) async throws -> [AIModelDescriptor]
  let setRemoteAIEnabled: (Bool) -> Void
  let grantDataSharingConsent: () -> Void
  let revokeDataSharingConsent: () -> Void
  let isCodexDataSharingConsentGranted: (CodexAppServerAccountStatus?) -> Bool
  let grantCodexDataSharingConsent: (CodexAppServerAccountStatus) -> Void
  let openSiteAISettings: () -> Void

  @State private var aiAPIKeyInput = ""
  @State private var aiConnectionReport: AIConnectionTestReport?
  @State private var isConnectionReportStale = false
  @State private var connectionTestTask: Task<Void, Never>?
  @State private var connectionTestRequestID = UUID()
  @State private var hasAttemptedConnectionTest = false
  @State private var selectedCapabilityProbes: Set<AIProviderCapabilityProbeKind> = []
  @State private var connectionUpdateFailed = false
  @State private var modelDiscoveryTrigger = UUID()
  @State private var setupFocusAPIKey = false
  @State private var setupFocusRequestID = UUID()

  var body: some View {
    ScrollViewReader { scrollProxy in
      Form {
        AIConnectionProfilesSection(
          profiles: connectionProfiles,
          referencingSiteProfiles: referencingSiteProfiles,
          selectedProfileID: .constant(activeConnectionProfileID),
          updateProfile: { profile in
            _ = commitConnectionUpdate(profile)
          },
          createProfile: createConnectionProfile,
          duplicateProfileForCurrentSite: duplicateConnectionProfile,
          currentActionMessage: currentActionMessage,
          deleteProfile: deleteConnectionProfile,
          deletableProfiles: deletableConnectionProfiles,
          presentation: .sharedEditor,
          currentSiteName: activeProfile.name,
          editSharedConnection: nil,
          subsectionAnchor: .aiConnection
        )

        Section {
          Button("选择当前站点的连接", action: openSiteAISettings)
            .accessibilityIdentifier("settings-ai-open-site-connection")
        } footer: {
          Text("此页只编辑当前站点正在使用的共享连接。请在站点 AI 设置中选择、新建或复制连接。")
        }

        AIConnectionSetupSection(
          config: activeConnection.config,
          presentation: setupPresentation,
          isAIActionRunning: isActionRunning
        ) {
          continueSetup(using: scrollProxy)
        }

        AIProviderSection(
          presetBinding: aiPresetBinding,
          presetDisplayName: activeConnection.config.preset.localizedDisplayName,
          baseURL: aiProviderStringBinding(\.baseURL),
          baseURLDisplayValue: activeConnection.config.baseURL,
          model: aiProviderStringBinding(\.model),
          modelDisplayValue: activeConnection.config.model,
          requiresAPIKeyBinding: aiProviderBoolBinding(\.requiresAPIKey),
          requiresAPIKeyDisplayValue: activeConnection.config.requiresAPIKey
            ? String(localized: "开启")
            : String(localized: "关闭"),
          connectionProfileID: activeConnection.id,
          discoverModels: discoverModels,
          modelDiscoveryTrigger: modelDiscoveryTrigger,
          modelDiscoveryAuthorizationMessage: modelDiscoveryAuthorizationMessage
        )
        .id("ai-setup-provider")

        if connectionUpdateFailed {
          AccessibleStatusMessage(
            message: connectionUpdateFailureMessage,
            severity: .error
          )
          .textSelection(.enabled)
          .accessibilityIdentifier("settings-ai-connection-update-error")
        }

        if activeConnection.config.usesCodexAppServer {
          codexAccountSection.id("ai-setup-codex")
        } else {
          if activeConnection.config.preset == .local {
            LocalAIEngineDiscoverySection { baseURL, model in
              applyLocalAIConfiguration(baseURL: baseURL, model: model)
            }
            .id("ai-setup-local")
          } else {
            AIKeychainSection(
              aiAPIKeyInput: $aiAPIKeyInput,
              shouldFocusInput: shouldFocusAPIKey || setupFocusAPIKey,
              navigationRequestID: setupFocusAPIKey
                ? setupFocusRequestID : healthNavigationRequestID,
              config: activeConnection.config,
              storageMode: credentialStorageMode,
              tokenAvailability: tokenAvailability,
              actionMessage: actionMessage,
              onSaveAPIKey: {
                connectionUpdateFailed = false
                guard saveAPIKey(aiAPIKeyInput) else { return false }
                aiAPIKeyInput = ""
                invalidateConnectionReport()
                return true
              },
              onDeleteAPIKey: {
                connectionUpdateFailed = false
                deleteAPIKey()
                aiAPIKeyInput = ""
                invalidateConnectionReport()
              },
              onRefreshState: refreshKeyAvailability,
              onChangeStorageMode: { mode in
                connectionUpdateFailed = false
                setCredentialStorageMode(mode)
                aiAPIKeyInput = ""
                invalidateConnectionReport()
              }
            )
            .id("ai-setup-credentials")
          }

          AIConnectionTestSection(
            config: activeConnection.config,
            tokenAvailability: tokenAvailability,
            dataSharingConsent: dataSharingConsent,
            report: isConnectionReportStale ? nil : aiConnectionReport,
            isReportStale: isConnectionReportStale,
            isAIActionRunning: isActionRunning,
            isConnectionTestRunning: connectionTestTask != nil,
            hasAttemptedConnectionTest: hasAttemptedConnectionTest,
            actionMessage: actionMessage,
            selectedProbeCapabilities: $selectedCapabilityProbes,
            onTestConnection: startConnectionTest
          )
          .id("ai-setup-test")
        }

        AIAdvancedSettingsSection(
          settings: aiAdvancedSettingsBinding,
          reasoningSupport: activeConnection.config.capabilitySupport(for: .reasoningControl),
          usesCodexAppServer: activeConnection.config.usesCodexAppServer,
          subsectionAnchor: .aiAdvanced
        )
        AIProviderCapabilitiesSection(config: activeConnection.config)
        AIDataSharingConsentSection(
          presentation: dataSharingConsent,
          isCodexAppServer: activeConnection.config.usesCodexAppServer,
          setRemoteAIEnabled: { enabled in
            setRemoteAIEnabled(enabled)
            invalidateConnectionReport()
          },
          grantConsent: {
            grantDataSharingConsent()
            invalidateConnectionReport()
          },
          revokeConsent: {
            revokeDataSharingConsent()
            invalidateConnectionReport()
          }
        )
        .id("ai-setup-consent")
        if activeConnection.config.preset != .local && !activeConnection.config.usesCodexAppServer {
          LocalAIEngineDiscoverySection { baseURL, model in
            applyLocalAIConfiguration(baseURL: baseURL, model: model)
          }
        }

      }
      .formStyle(.grouped)
      .scrollIndicators(.hidden)
      .padding(WorkbenchSpacing.content)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .onChange(of: aiAPIKeyInput) { _, _ in
        invalidateConnectionReport()
      }
      .onChange(of: activeConnection.config) { oldConfig, newConfig in
        guard
          configurationWithoutProbeEvidence(oldConfig)
            != configurationWithoutProbeEvidence(newConfig)
        else { return }
        invalidateConnectionReport()
      }
      .onChange(of: activeConnectionProfileID) { _, _ in
        aiAPIKeyInput = ""
        connectionUpdateFailed = false
        selectedCapabilityProbes = []
        invalidateConnectionReport()
      }
      .onChange(of: tokenAvailability) { _, _ in
        invalidateConnectionReport()
        if modelDiscoveryAuthorizationMessage == nil { modelDiscoveryTrigger = UUID() }
      }
      .onChange(of: dataSharingConsent) { _, _ in
        invalidateConnectionReport()
        if modelDiscoveryAuthorizationMessage == nil { modelDiscoveryTrigger = UUID() }
      }
      .onDisappear {
        connectionTestTask?.cancel()
        connectionTestTask = nil
      }
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("ai-settings")
    }
  }

  private var setupPresentation: AIConnectionSetupPresentation {
    AIConnectionSetupPresentation.make(
      config: activeConnection.config,
      tokenAvailability: tokenAvailability,
      dataSharingConsent: dataSharingConsent,
      report: isConnectionReportStale ? nil : aiConnectionReport,
      isTesting: connectionTestTask != nil
    )
  }

  private var modelDiscoveryAuthorizationMessage: String? {
    if activeConnection.config.usesCodexAppServer { return String(localized: "请在账户连接中刷新模型。") }
    if activeConnection.config.requiresAPIKey {
      if let message = tokenAvailability.accessFailureMessage { return message }
      if !tokenAvailability.hasToken { return String(localized: "先保存 API Key，再获取可用模型。") }
    }
    if !dataSharingConsent.isGranted { return String(localized: "先完成下方数据发送授权，再获取模型列表。") }
    return nil
  }

  private func continueSetup(using proxy: ScrollViewProxy) {
    if activeConnection.config.usesCodexAppServer {
      proxy.scrollTo("ai-setup-codex", anchor: .top)
      return
    }
    if activeConnection.config.preset == .local {
      proxy.scrollTo("ai-setup-local", anchor: .top)
      return
    }
    switch setupPresentation.nextStep {
    case .missingBaseURL, .invalidEndpoint:
      proxy.scrollTo("ai-setup-provider", anchor: .top)
    case .missingAPIKey, .credentialAccessFailed:
      setupFocusAPIKey = true
      setupFocusRequestID = UUID()
      proxy.scrollTo("ai-setup-credentials", anchor: .top)
    case .consentRequired:
      proxy.scrollTo("ai-setup-consent", anchor: .top)
    case .missingModel:
      modelDiscoveryTrigger = UUID()
      proxy.scrollTo("ai-setup-provider", anchor: .top)
    case .ready, .changedGateway, .success:
      startConnectionTest()
      proxy.scrollTo("ai-setup-test", anchor: .top)
    case .testing: break
    }
  }

  private var codexAccountSection: some View {
    CodexAppServerAccountSection(
      model: aiProviderStringBinding(\.model),
      reasoningEffortOverride: aiReasoningEffortOverrideBinding,
      isCodexDataSharingConsentGranted: isCodexDataSharingConsentGranted,
      grantConsentForConnection: {
        grantCodexDataSharingConsent($0)
        invalidateConnectionReport()
      },
      testConnection: {
        let report = await testConnection([])
        await MainActor.run {
          hasAttemptedConnectionTest = true
          aiConnectionReport = report
          isConnectionReportStale = false
        }
        return report
      }
    )
  }

  private var activeProfile: SiteProfile {
    activeProfileBinding.wrappedValue
  }

  private var activeConnection: AIConnectionProfile {
    connectionProfiles.first(where: { $0.id == activeConnectionProfileID })
      ?? AIConnectionProfile(
        id: activeConnectionProfileID,
        name: activeProfile.aiProviderConfig.normalizedDisplayName,
        config: activeProfile.aiProviderConfig
      )
  }

  private var aiPresetBinding: Binding<AIProviderPreset> {
    Binding(
      get: { activeConnection.config.preset },
      set: { preset in
        invalidateConnectionReport()
        var connection = activeConnection
        connection.config.preset = preset
        connection.config.applyPresetDefaults()
        _ = commitConnectionUpdate(connection)
      }
    )
  }

  private func aiProviderStringBinding(
    _ keyPath: WritableKeyPath<AIProviderConfig, String>
  ) -> Binding<String> {
    Binding(
      get: { activeConnection.config[keyPath: keyPath] },
      set: { value in
        invalidateConnectionReport()
        var connection = activeConnection
        connection.config[keyPath: keyPath] = value
        _ = commitConnectionUpdate(connection)
      }
    )
  }

  private func aiProviderBoolBinding(
    _ keyPath: WritableKeyPath<AIProviderConfig, Bool>
  ) -> Binding<Bool> {
    Binding(
      get: { activeConnection.config[keyPath: keyPath] },
      set: { value in
        invalidateConnectionReport()
        var connection = activeConnection
        connection.config[keyPath: keyPath] = value
        _ = commitConnectionUpdate(connection)
      }
    )
  }

  private var aiAdvancedSettingsBinding: Binding<AIProviderAdvancedSettings> {
    Binding(
      get: { activeConnection.config.resolvedAdvancedSettings },
      set: { settings in
        invalidateConnectionReport()
        var connection = activeConnection
        connection.config.advancedSettings = settings.isDefault ? nil : settings
        _ = commitConnectionUpdate(connection)
      }
    )
  }

  private var aiReasoningEffortOverrideBinding: Binding<String?> {
    Binding(
      get: { activeConnection.config.resolvedAdvancedSettings.reasoningEffortOverride },
      set: { value in
        var settings = activeConnection.config.resolvedAdvancedSettings
        settings.reasoningEffortOverride = value
        aiAdvancedSettingsBinding.wrappedValue = settings
      }
    )
  }

  private func applyLocalAIConfiguration(baseURL: String, model: String) -> Bool {
    invalidateConnectionReport()
    var connection = activeConnection
    connection.config.preset = .local
    connection.config.baseURL = baseURL
    connection.config.model = model
    connection.config.requiresAPIKey = false
    return commitConnectionUpdate(connection)
  }

  @discardableResult
  private func commitConnectionUpdate(_ connection: AIConnectionProfile) -> Bool {
    let didUpdate = updateConnectionProfile(connection)
    connectionUpdateFailed = !didUpdate
    return didUpdate
  }

  private var connectionUpdateFailureMessage: String {
    guard let actionMessage = actionMessage?.trimmedForPublishing.nilIfEmpty,
      Self.isActionableConnectionFailureMessage(actionMessage)
    else {
      return String(localized: "AI 连接未更改，请检查凭据和地址后重试。")
    }
    return actionMessage
  }

  private static func isActionableConnectionFailureMessage(_ message: String) -> Bool {
    let lowercasedMessage = message.lowercased()
    return message.contains("失败")
      || message.contains("未更改")
      || message.contains("未切换")
      || lowercasedMessage.contains("failed")
      || lowercasedMessage.contains("error")
  }

  private func invalidateConnectionReport() {
    connectionTestRequestID = UUID()
    connectionTestTask?.cancel()
    connectionTestTask = nil
    hasAttemptedConnectionTest = false
    guard aiConnectionReport != nil else { return }
    isConnectionReportStale = true
  }

  private func startConnectionTest() {
    guard !isActionRunning else { return }
    connectionTestTask?.cancel()
    let requestID = UUID()
    let connectionID = activeConnection.id
    let config = activeConnection.config
    connectionTestRequestID = requestID
    aiConnectionReport = nil
    isConnectionReportStale = false
    hasAttemptedConnectionTest = true

    connectionTestTask = Task { @MainActor in
      defer {
        // A newer request owns the marker after a superseding edit or test;
        // otherwise every exit path, including cancellation, clears it.
        if connectionTestRequestID == requestID {
          connectionTestTask = nil
        }
      }
      let report = await testConnection(selectedCapabilityProbes)
      guard !Task.isCancelled,
        connectionTestRequestID == requestID,
        activeConnection.id == connectionID,
        configurationWithoutProbeEvidence(activeConnection.config)
          == configurationWithoutProbeEvidence(config)
      else {
        return
      }
      aiConnectionReport = report
      isConnectionReportStale = false
    }
  }

  private func configurationWithoutProbeEvidence(
    _ config: AIProviderConfig
  ) -> AIProviderConfig {
    var sanitized = config
    sanitized.capabilityProbeEvidence = nil
    return sanitized
  }

}
