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
  let tokenAvailability: KeychainTokenAvailability
  let isActionRunning: Bool
  let actionMessage: String?
  let dataSharingConsent: AIDataSharingConsentPresentation
  let shouldFocusAPIKey: Bool
  let navigationRequestID: UUID
  let saveAPIKey: (String) -> Bool
  let deleteAPIKey: () -> Void
  let refreshKeyAvailability: () -> Void
  let testConnection: () async -> AIConnectionTestReport?
  let grantDataSharingConsent: () -> Void
  let revokeDataSharingConsent: () -> Void
  let selectedDraftTitle: String?
  let appendLocalWhisperTranscript: (String) -> Bool

  @State private var aiAPIKeyInput = ""
  @State private var aiConnectionReport: AIConnectionTestReport?
  @State private var isConnectionReportStale = false
  @State private var connectionTestTask: Task<Void, Never>?
  @State private var connectionTestRequestID = UUID()
  @State private var selectedSection: AISettingsSection = .connection

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
              _ = updateConnectionProfile(profile)
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
              : String(localized: "关闭")
          )

          AIProviderCapabilitiesSection(config: activeConnection.config)

          AIAdvancedSettingsSection(
            settings: aiAdvancedSettingsBinding,
            reasoningSupport: activeConnection.config.capabilitySupport(
              for: .reasoningControl
            )
          )

          LocalAIEngineDiscoverySection { baseURL, model in
            applyLocalAIConfiguration(baseURL: baseURL, model: model)
          }

          LocalWhisperSection(
            selectedDraftTitle: selectedDraftTitle,
            appendTranscript: appendLocalWhisperTranscript
          )

        case .credentials:
          AIKeychainSection(
            aiAPIKeyInput: $aiAPIKeyInput,
            shouldFocusInput: shouldFocusAPIKey,
            navigationRequestID: navigationRequestID,
            config: activeConnection.config,
            tokenAvailability: tokenAvailability,
            connectionReport: isConnectionReportStale ? nil : aiConnectionReport,
            isConnectionReportStale: isConnectionReportStale,
            isAIActionRunning: isActionRunning,
            isConnectionTestRunning: connectionTestTask != nil,
            actionMessage: actionMessage,
            onSaveAPIKey: {
              guard saveAPIKey(aiAPIKeyInput) else { return }
              aiAPIKeyInput = ""
              invalidateConnectionReport()
            },
            onDeleteAPIKey: {
              deleteAPIKey()
              aiAPIKeyInput = ""
              invalidateConnectionReport()
            },
            onRefreshState: refreshKeyAvailability,
            onTestConnection: {
              startConnectionTest()
            }
          )

          AIDataSharingConsentSection(
            presentation: dataSharingConsent,
            grantConsent: grantDataSharingConsent,
            revokeConsent: revokeDataSharingConsent
          )

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
      .scrollIndicators(.hidden)
      .padding(WorkbenchSpacing.content)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .task(id: navigationRequestID) {
      guard shouldFocusAPIKey else { return }
      selectedSection = .credentials
    }
    .onChange(of: aiAPIKeyInput) { _, _ in
      invalidateConnectionReport()
    }
    .onChange(of: activeConnection.config) { _, _ in
      invalidateConnectionReport()
    }
    .onChange(of: selectedConnectionProfileID.wrappedValue) { _, _ in
      aiAPIKeyInput = ""
      invalidateConnectionReport()
    }
    .onChange(of: tokenAvailability.accessState) { _, _ in
      invalidateConnectionReport()
    }
    .onDisappear {
      connectionTestTask?.cancel()
      connectionTestTask = nil
    }
    .accessibilityIdentifier("ai-settings")
  }

  private var aiSettingsHeader: some View {
    SettingsScopeHeader(minimumLeadingWidth: 280, scopeControlWidth: 340) {
      aiStatusHeaderBanner
    } scopeControl: {
      aiSettingsPicker
    }
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
        _ = updateConnectionProfile(connection)
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

  private func aiWritingStyleTextBinding(_ keyPath: WritableKeyPath<AIWritingStyleConfig, String>) -> Binding<String> {
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
        _ = updateConnectionProfile(connection)
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
        _ = updateConnectionProfile(connection)
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
        _ = updateConnectionProfile(connection)
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
    return updateConnectionProfile(connection)
  }

  private func invalidateConnectionReport() {
    connectionTestRequestID = UUID()
    connectionTestTask?.cancel()
    connectionTestTask = nil
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

    connectionTestTask = Task { @MainActor in
      let report = await testConnection()
      guard !Task.isCancelled,
            connectionTestRequestID == requestID,
            activeConnection.id == connectionID,
            activeConnection.config == config else {
        return
      }
      aiConnectionReport = report
      isConnectionReportStale = false
      connectionTestTask = nil
    }
  }

  private var aiStatusHeaderBanner: some View {
    HStack(spacing: WorkbenchSpacing.card) {
      ZStack {
        Circle()
          .fill(Color.accentColor.opacity(0.15))
          .frame(width: 36, height: 36)
        Image(systemName: "sparkles")
          .font(.title3.weight(.semibold))
          .foregroundStyle(Color.accentColor)
      }

      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 6) {
          Text(String(localized: "AI 创作引擎"))
            .font(.subheadline.weight(.semibold))
          Text(verbatim: activeConnection.config.preset.localizedDisplayName)
            .font(.workbenchMetadata.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.primary.opacity(0.08), in: Capsule())
        }

        Group {
          if activeConnection.config.normalizedModel.isEmpty {
            Text(String(localized: "模型"))
          } else {
            Text(
              String(
                format: String(localized: "模型：%@"),
                activeConnection.config.normalizedModel
              )
            )
          }
        }
        .font(.caption.monospaced())
        .foregroundStyle(.secondary)
      }

      Spacer(minLength: WorkbenchSpacing.control)

      HStack(spacing: 5) {
        Circle()
          .fill(aiCredentialStatusColor)
          .frame(width: 8, height: 8)
        Text(aiCredentialStatusTitle)
          .font(.workbenchMetadata.weight(.medium))
          .foregroundStyle(aiCredentialStatusColor)
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .background(
        aiCredentialStatusColor.opacity(0.12),
        in: Capsule()
      )
    }
    .padding(WorkbenchSpacing.card)
    .background(
      WorkbenchBackgroundStyle.panel,
      in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card, style: .continuous)
    )
    .overlay(
      RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card, style: .continuous)
        .stroke(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 1)
    )
    .accessibilityElement(children: .combine)
  }

  private var aiCredentialStatusTitle: LocalizedStringKey {
    guard activeConnection.config.requiresAPIKey else {
      return "无需 API Key"
    }
    switch tokenAvailability.accessState {
    case .available:
      return "凭据就绪"
    case .missing:
      return "待配置 Key"
    case .accessFailed:
      return "Keychain 读取失败"
    }
  }

  private var aiCredentialStatusColor: Color {
    !activeConnection.config.requiresAPIKey || tokenAvailability.accessState == .available
      ? WorkbenchTheme.success
      : WorkbenchTheme.warning
  }
}

private enum AISettingsSection: String, CaseIterable, Identifiable {
  case connection
  case credentials
  case writingStyle

  var id: String { rawValue }

  var title: String {
    switch self {
    case .connection:
      return String(localized: "服务与连接")
    case .credentials:
      return String(localized: "钥匙串凭据")
    case .writingStyle:
      return String(localized: "写作风格")
    }
  }

  var systemImage: String {
    switch self {
    case .connection:
      return "point.3.connected.trianglepath.dotted"
    case .credentials:
      return "key"
    case .writingStyle:
      return "text.quote"
    }
  }
}
