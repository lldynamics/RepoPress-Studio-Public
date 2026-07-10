import PublishingWorkbenchCore
import SwiftUI

struct AISettingsView: View {
  let activeProfileBinding: Binding<SiteProfile>
  let tokenAvailability: KeychainTokenAvailability
  let isActionRunning: Bool
  let actionMessage: String?
  let saveAPIKey: (String) -> Void
  let deleteAPIKey: () -> Void
  let refreshKeyAvailability: () -> Void
  let testConnection: () async -> AIConnectionTestReport?

  @State private var aiAPIKeyInput = ""
  @State private var aiConnectionReport: AIConnectionTestReport?

  var body: some View {
    Form {
      AIProviderSection(
        presetBinding: aiPresetBinding,
        presetDisplayName: activeProfile.aiProviderConfig.preset.displayName,
        baseURL: activeProfileBinding.aiProviderConfig.baseURL,
        baseURLDisplayValue: activeProfile.aiProviderConfig.baseURL,
        model: activeProfileBinding.aiProviderConfig.model,
        modelDisplayValue: activeProfile.aiProviderConfig.model,
        requiresAPIKeyBinding: activeProfileBinding.aiProviderConfig.requiresAPIKey,
        requiresAPIKeyDisplayValue: activeProfile.aiProviderConfig.requiresAPIKey ? "开启" : "关闭",
        applyCurrentPreset: {
          applyCurrentAIPreset()
        }
      )

      AIWritingStyleSection(
        presetBinding: aiWritingStylePresetBinding,
        presetDisplayName: activeProfile.resolvedAIWritingStyle.preset.displayName,
        applyPresetTemplate: {
          applySelectedAIWritingStylePreset()
        },
        toneText: aiWritingStyleTextBinding(\.tone),
        audienceText: aiWritingStyleTextBinding(\.audience),
        summaryGuidanceText: aiWritingStyleTextBinding(\.summaryGuidance),
        tagGuidanceText: aiWritingStyleTextBinding(\.tagGuidance),
        seoGuidanceText: aiWritingStyleTextBinding(\.seoGuidance),
        isPresetCustom: activeProfile.resolvedAIWritingStyle.preset == .custom
      )

      AIKeychainSection(
        aiAPIKeyInput: $aiAPIKeyInput,
        config: activeProfile.aiProviderConfig,
        tokenAvailability: tokenAvailability,
        connectionReport: aiConnectionReport,
        isAIActionRunning: isActionRunning,
        actionMessage: actionMessage,
        onSaveAPIKey: {
          saveAPIKey(aiAPIKeyInput)
          aiAPIKeyInput = ""
        },
        onDeleteAPIKey: {
          deleteAPIKey()
          aiAPIKeyInput = ""
        },
        onRefreshState: {
          refreshKeyAvailability()
        },
        onTestConnection: {
          Task {
            aiConnectionReport = await testConnection()
          }
        }
      )
    }
    .formStyle(.grouped)
    .padding()
  }

  private var activeProfile: SiteProfile {
    activeProfileBinding.wrappedValue
  }

  private var aiPresetBinding: Binding<AIProviderPreset> {
    Binding(
      get: { activeProfileBinding.wrappedValue.aiProviderConfig.preset },
      set: { preset in
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

  private func applyCurrentAIPreset() {
    var profile = activeProfileBinding.wrappedValue
    profile.aiProviderConfig.applyPresetDefaults()
    activeProfileBinding.wrappedValue = profile
    aiConnectionReport = nil
  }

  private func applySelectedAIWritingStylePreset() {
    var profile = activeProfileBinding.wrappedValue
    var style = profile.resolvedAIWritingStyle
    style.applyPreset(style.preset)
    profile.resolvedAIWritingStyle = style
    activeProfileBinding.wrappedValue = profile
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
}
