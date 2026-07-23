import PublishingWorkbenchCore
import SwiftUI

struct AISettingsView: View {
  let activeProfileBinding: Binding<SiteProfile>
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

  @State private var aiAPIKeyInput = ""
  @State private var aiConnectionReport: AIConnectionTestReport?
  @State private var isConnectionReportStale = false
  @State private var selectedSection: AISettingsSection = .connection

  var body: some View {
    VStack(spacing: 0) {
      Picker("AI 设置范围", selection: $selectedSection) {
        ForEach(AISettingsSection.allCases) { section in
          Text(section.title).tag(section)
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .frame(maxWidth: 360)
      .padding(.horizontal, 18)
      .padding(.vertical, 12)
      .accessibilityLabel("AI 设置范围")

      Divider()

      Form {
        switch selectedSection {
        case .connection:
          AIProviderSection(
            presetBinding: aiPresetBinding,
            presetDisplayName: activeProfile.aiProviderConfig.preset.localizedDisplayName,
            baseURL: aiProviderStringBinding(\.baseURL),
            baseURLDisplayValue: activeProfile.aiProviderConfig.baseURL,
            model: aiProviderStringBinding(\.model),
            modelDisplayValue: activeProfile.aiProviderConfig.model,
            requiresAPIKeyBinding: aiProviderBoolBinding(\.requiresAPIKey),
            requiresAPIKeyDisplayValue: activeProfile.aiProviderConfig.requiresAPIKey ? "开启" : "关闭"
          )

          AIDataSharingConsentSection(
            presentation: dataSharingConsent,
            grantConsent: grantDataSharingConsent,
            revokeConsent: revokeDataSharingConsent
          )

          AIKeychainSection(
            aiAPIKeyInput: $aiAPIKeyInput,
            shouldFocusInput: shouldFocusAPIKey,
            navigationRequestID: navigationRequestID,
            config: activeProfile.aiProviderConfig,
            tokenAvailability: tokenAvailability,
            connectionReport: aiConnectionReport,
            isConnectionReportStale: isConnectionReportStale,
            isAIActionRunning: isActionRunning,
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
              Task {
                aiConnectionReport = await testConnection()
                isConnectionReportStale = false
              }
            }
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
      .padding()
    }
    .task(id: navigationRequestID) {
      guard shouldFocusAPIKey else { return }
      selectedSection = .connection
    }
    .onChange(of: aiAPIKeyInput) { _, _ in
      invalidateConnectionReport()
    }
    .onChange(of: activeProfile.aiProviderConfig) { _, _ in
      invalidateConnectionReport()
    }
    .onChange(of: tokenAvailability.hasToken) { _, _ in
      invalidateConnectionReport()
    }
  }

  private var activeProfile: SiteProfile {
    activeProfileBinding.wrappedValue
  }

  private var aiPresetBinding: Binding<AIProviderPreset> {
    Binding(
      get: { activeProfileBinding.wrappedValue.aiProviderConfig.preset },
      set: { preset in
        invalidateConnectionReport()
        var profile = activeProfileBinding.wrappedValue
        profile.aiProviderConfig.preset = preset
        profile.aiProviderConfig.applyPresetDefaults()
        activeProfileBinding.wrappedValue = profile
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
      get: { activeProfileBinding.wrappedValue.aiProviderConfig[keyPath: keyPath] },
      set: { value in
        invalidateConnectionReport()
        var profile = activeProfileBinding.wrappedValue
        profile.aiProviderConfig[keyPath: keyPath] = value
        activeProfileBinding.wrappedValue = profile
      }
    )
  }

  private func aiProviderBoolBinding(
    _ keyPath: WritableKeyPath<AIProviderConfig, Bool>
  ) -> Binding<Bool> {
    Binding(
      get: { activeProfileBinding.wrappedValue.aiProviderConfig[keyPath: keyPath] },
      set: { value in
        invalidateConnectionReport()
        var profile = activeProfileBinding.wrappedValue
        profile.aiProviderConfig[keyPath: keyPath] = value
        activeProfileBinding.wrappedValue = profile
      }
    )
  }

  private func invalidateConnectionReport() {
    guard aiConnectionReport != nil else { return }
    isConnectionReportStale = true
  }
}

private enum AISettingsSection: String, CaseIterable, Identifiable {
  case connection
  case writingStyle

  var id: String { rawValue }

  var title: String {
    switch self {
    case .connection:
      return String(localized: "服务与连接")
    case .writingStyle:
      return String(localized: "写作风格")
    }
  }
}
