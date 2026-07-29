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
      aiStatusHeaderBanner
        .padding(.horizontal, 16)
        .padding(.top, 12)

      Picker("AI 设置范围", selection: $selectedSection) {
        ForEach(AISettingsSection.allCases) { section in
          Text(section.title).tag(section)
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .frame(maxWidth: 360)
      .padding(.horizontal, 18)
      .padding(.vertical, 10)
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

  private var aiStatusHeaderBanner: some View {
    HStack(spacing: 12) {
      ZStack {
        Circle()
          .fill(Color.accentColor.opacity(0.15))
          .frame(width: 36, height: 36)
        Image(systemName: "sparkles")
          .font(.system(size: 18, weight: .semibold))
          .foregroundStyle(Color.accentColor)
      }

      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 6) {
          Text("AI 创作引擎")
            .font(.subheadline.weight(.semibold))
          Text(activeProfile.aiProviderConfig.preset.localizedDisplayName)
            .font(.workbenchMetadata.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.primary.opacity(0.08), in: Capsule())
        }

        Text("模型: \(activeProfile.aiProviderConfig.model.isEmpty ? "默认" : activeProfile.aiProviderConfig.model)")
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
      }

      Spacer()

      HStack(spacing: 5) {
        Circle()
          .fill(tokenAvailability.hasToken ? WorkbenchTheme.success : WorkbenchTheme.warning)
          .frame(width: 8, height: 8)
        Text(tokenAvailability.hasToken ? "凭据就绪" : "待配置 Key")
          .font(.workbenchMetadata.weight(.medium))
          .foregroundStyle(tokenAvailability.hasToken ? WorkbenchTheme.success : WorkbenchTheme.warning)
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .background(
        (tokenAvailability.hasToken ? WorkbenchTheme.success : WorkbenchTheme.warning).opacity(0.12),
        in: Capsule()
      )
    }
    .padding(12)
    .background(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .fill(.ultraThinMaterial)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .stroke(Color.primary.opacity(0.1), lineWidth: 1)
    )
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
