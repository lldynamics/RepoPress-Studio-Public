import PublishingWorkbenchCore
import SwiftUI

struct AISettingsView: View {
  let activeProfileBinding: Binding<SiteProfile>
  let connectionProfiles: [AIConnectionProfile]
  let selectedConnectionProfileID: Binding<UUID>
  let updateConnectionProfile: (AIConnectionProfile) -> Bool
  let createConnectionProfile: (String, AIProviderPreset) -> AIConnectionProfile
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

  @State private var aiAPIKeyInput = ""
  @State private var aiConnectionReport: AIConnectionTestReport?
  @State private var isConnectionReportStale = false
  @State private var connectionTestTask: Task<Void, Never>?
  @State private var connectionTestRequestID = UUID()
  @State private var selectedSection: AISettingsSection = .connection
  @State private var hasAttemptedConnectionTest = false
  @State private var selectedCapabilityProbes: Set<AIProviderCapabilityProbeKind> = []
  @State private var connectionUpdateFailed = false

  var body: some View {
    VStack(spacing: 0) {
      aiSettingsHeader

      Divider()

      Form {
        switch selectedSection {
        case .connection:
          AIConnectionProfilesSection(
            profiles: connectionProfiles,
            selectedProfileID: selectedConnectionProfileID,
            updateProfile: { profile in
              _ = commitConnectionUpdate(profile)
            },
            createProfile: createConnectionProfile,
            deleteProfile: deleteConnectionProfile,
            deletableProfiles: deletableConnectionProfiles
          )

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
            discoverModels: discoverModels
          )

          if connectionUpdateFailed {
            AccessibleStatusMessage(
              message: connectionUpdateFailureMessage,
              severity: .error
            )
            .textSelection(.enabled)
            .accessibilityIdentifier("settings-ai-connection-update-error")
          }

          if activeConnection.config.usesCodexAppServer {
            codexAccountSection
          } else {
            if activeConnection.config.preset == .local {
              LocalAIEngineDiscoverySection { baseURL, model in
                applyLocalAIConfiguration(baseURL: baseURL, model: model)
              }
            } else {
              AIKeychainSection(
                aiAPIKeyInput: $aiAPIKeyInput,
                shouldFocusInput: shouldFocusAPIKey,
                navigationRequestID: healthNavigationRequestID,
                config: activeConnection.config,
                storageMode: credentialStorageMode,
                tokenAvailability: tokenAvailability,
                actionMessage: actionMessage,
                onSaveAPIKey: {
                  connectionUpdateFailed = false
                  guard saveAPIKey(aiAPIKeyInput) else { return }
                  aiAPIKeyInput = ""
                  invalidateConnectionReport()
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
          }

        case .credentials:
          AIAdvancedSettingsSection(
            settings: aiAdvancedSettingsBinding,
            reasoningSupport: activeConnection.config.capabilitySupport(
              for: .reasoningControl
            ),
            usesCodexAppServer: activeConnection.config.usesCodexAppServer
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

          if activeConnection.config.preset != .local && !activeConnection.config.usesCodexAppServer
          {
            LocalAIEngineDiscoverySection { baseURL, model in
              applyLocalAIConfiguration(baseURL: baseURL, model: model)
            }
          }

        case .writingStyle:
          AIWritingStyleSection(
            presetBinding: aiWritingStylePresetBinding,
            presetDisplayName: activeProfile.resolvedAIWritingStyle.preset.localizedDisplayName,
            toneText: aiWritingStyleTextBinding(\.tone),
            audienceText: aiWritingStyleTextBinding(\.audience),
            summaryGuidanceText: aiWritingStyleTextBinding(\.summaryGuidance),
            tagGuidanceText: aiWritingStyleTextBinding(\.tagGuidance),
            seoGuidanceText: aiWritingStyleTextBinding(\.seoGuidance)
          )
        }
      }
      .formStyle(.grouped)
      .scrollIndicators(.automatic)
      .padding(WorkbenchSpacing.content)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .task(id: healthNavigationRequestID) {
      guard shouldFocusAPIKey else { return }
      selectedSection = .connection
    }
    .task(id: navigationRequestID) {
      applyNavigationDestination()
    }
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
    .onChange(of: selectedConnectionProfileID.wrappedValue) { _, _ in
      aiAPIKeyInput = ""
      connectionUpdateFailed = false
      selectedCapabilityProbes = []
      invalidateConnectionReport()
    }
    .onChange(of: tokenAvailability.accessState) { _, _ in
      invalidateConnectionReport()
    }
    .onDisappear {
      connectionTestTask?.cancel()
      connectionTestTask = nil
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("ai-settings")
  }

  private var aiSettingsHeader: some View {
    SettingsScopeHeader(minimumLeadingWidth: 220, scopeControlWidth: 400) {
      aiCompactSummary
    } scopeControl: {
      aiSettingsPicker
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

  private var aiSettingsPicker: some View {
    Picker("AI 设置分类", selection: $selectedSection) {
      ForEach(AISettingsSection.allCases) { section in
        Text(section.title).tag(section)
      }
    }
    .pickerStyle(.segmented)
    .labelsHidden()
    .accessibilityLabel("AI 设置分类")
    .accessibilityIdentifier("settings-ai-section-picker")
  }

  private var activeProfile: SiteProfile {
    activeProfileBinding.wrappedValue
  }

  private var activeConnection: AIConnectionProfile {
    connectionProfiles.first(where: { $0.id == selectedConnectionProfileID.wrappedValue })
      ?? AIConnectionProfile(
        id: selectedConnectionProfileID.wrappedValue,
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

  private var aiWritingStylePresetBinding: Binding<AIWritingStylePreset> {
    Binding(
      get: { activeProfileBinding.wrappedValue.resolvedAIWritingStyle.preset },
      set: { preset in
        var profile = activeProfileBinding.wrappedValue
        var style = profile.resolvedAIWritingStyle
        style.applyPreset(preset)
        profile.resolvedAIWritingStyle = style
        activeProfileBinding.wrappedValue = profile
      }
    )
  }

  private func aiWritingStyleTextBinding(_ keyPath: WritableKeyPath<AIWritingStyleConfig, String>)
    -> Binding<String>
  {
    Binding(
      get: { activeProfileBinding.wrappedValue.resolvedAIWritingStyle[keyPath: keyPath] },
      set: { value in
        var profile = activeProfileBinding.wrappedValue
        var style = profile.resolvedAIWritingStyle
        style.preset = .custom
        style[keyPath: keyPath] = value
        style.normalizeWhitespace()
        profile.resolvedAIWritingStyle = style
        activeProfileBinding.wrappedValue = profile
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

  private func applyNavigationDestination() {
    guard case .ai(let destination) = navigationDestination else { return }
    selectedSection = AISettingsSection(
      destination: destination,
      shouldFocusAPIKey: shouldFocusAPIKey
    )
  }

  private var aiCompactSummary: some View {
    HStack(spacing: 6) {
      Label(activeConnection.config.preset.localizedDisplayName, systemImage: "sparkles")
        .font(.callout.weight(.semibold))

      if activeConnection.config.usesCodexAppServer {
        Text(codexModelSummary)
          .font(.caption)
          .monospaced()
          .foregroundStyle(.secondary)
          .lineLimit(1)
      } else if !activeConnection.config.normalizedModel.isEmpty {
        Text(verbatim: activeConnection.config.normalizedModel)
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }

      Spacer(minLength: WorkbenchSpacing.control)

      Label(aiCredentialStatusTitle, systemImage: aiCredentialStatusSystemImage)
        .font(.caption.weight(.medium))
        .foregroundStyle(aiCredentialStatusColor)
        .lineLimit(1)
    }
    .accessibilityElement(children: .combine)
  }

  private var codexModelSummary: String {
    let model = activeConnection.config.normalizedModel
    return model == AIProviderPreset.codexDefaultModel
      ? String(localized: "账户默认模型")
      : (model.nilIfEmpty ?? String(localized: "账户默认模型"))
  }

  private var aiCredentialStatusTitle: LocalizedStringKey {
    if activeConnection.config.usesCodexAppServer {
      return "Codex 账户"
    }
    guard activeConnection.config.requiresAPIKey else {
      return "无需 API Key"
    }
    switch tokenAvailability.accessState {
    case .available:
      return "凭据就绪"
    case .missing:
      return "待配置 Key"
    case .accessFailed:
      return "凭据读取失败"
    }
  }

  private var aiCredentialStatusColor: Color {
    if activeConnection.config.usesCodexAppServer {
      return .secondary
    }
    return !activeConnection.config.requiresAPIKey || tokenAvailability.accessState == .available
      ? WorkbenchTheme.success
      : WorkbenchTheme.warning
  }

  private var aiCredentialStatusSystemImage: String {
    if activeConnection.config.usesCodexAppServer {
      return "person.crop.circle"
    }
    guard activeConnection.config.requiresAPIKey else {
      return "checkmark.circle"
    }
    switch tokenAvailability.accessState {
    case .available:
      return "checkmark.circle"
    case .missing:
      return "key"
    case .accessFailed:
      return "exclamationmark.triangle"
    }
  }
}

enum AISettingsSection: String, CaseIterable, Identifiable {
  case connection
  case credentials
  case writingStyle

  var id: String { rawValue }

  init(destination: SettingsAIDestination) {
    switch destination {
    case .connection:
      self = .connection
    case .credentials:
      self = .credentials
    case .writingStyle:
      self = .writingStyle
    }
  }

  init(destination: SettingsAIDestination, shouldFocusAPIKey: Bool) {
    if shouldFocusAPIKey {
      self = .connection
    } else {
      self.init(destination: destination)
    }
  }

  var title: String {
    switch self {
    case .connection:
      return String(localized: "模型与连接")
    case .credentials:
      return String(localized: "参数与网络")
    case .writingStyle:
      return String(localized: "写作风格")
    }
  }

  var systemImage: String {
    switch self {
    case .connection:
      return "sparkles"
    case .credentials:
      return "slider.horizontal.3"
    case .writingStyle:
      return "text.quote"
    }
  }
}
