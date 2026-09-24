import PublishingAICore
import PublishingWorkbenchCore
import SwiftUI

struct AISiteSettingsView: View {
  let activeProfileBinding: Binding<SiteProfile>
  let connectionProfiles: [AIConnectionProfile]
  let selectedConnectionProfileID: Binding<UUID>
  let createConnectionProfile: (String, AIProviderPreset) -> AIConnectionProfile
  let duplicateConnectionProfile: (UUID) -> AIConnectionProfile?
  let currentActionMessage: () -> String?
  let writingStyleArticles: [ArticleDraft]
  let writingStylePreview: AIWritingStyleProfilePreview?
  let isWritingStyleExtractionRunning: Bool
  let generateWritingStylePreview: (Set<UUID>) async -> AIWritingStyleProfilePreview?
  let applyWritingStylePreview: (AIWritingStyleProfilePreview) -> Bool
  let discardWritingStylePreview: () -> Void
  let openSharedConnectionSettings: () -> Void

  var body: some View {
    Form {
      AIConnectionProfilesSection(
        profiles: connectionProfiles,
        referencingSiteProfiles: [],
        selectedProfileID: selectedConnectionProfileID,
        updateProfile: { _ in },
        createProfile: createConnectionProfile,
        duplicateProfileForCurrentSite: duplicateConnectionProfile,
        currentActionMessage: currentActionMessage,
        deleteProfile: { _ in },
        deletableProfiles: [],
        presentation: .siteSelection,
        currentSiteName: activeProfile.name,
        editSharedConnection: openSharedConnectionSettings,
        subsectionAnchor: .aiSiteConnection
      )

      AIWritingStyleScopeNotice(siteName: activeProfile.name)
      AIWritingStyleSection(
        siteProfileID: activeProfile.id,
        presetBinding: aiWritingStylePresetBinding,
        presetDisplayName: activeProfile.resolvedAIWritingStyle.preset.localizedDisplayName,
        toneText: aiWritingStyleTextBinding(\.tone),
        audienceText: aiWritingStyleTextBinding(\.audience),
        summaryGuidanceText: aiWritingStyleTextBinding(\.summaryGuidance),
        tagGuidanceText: aiWritingStyleTextBinding(\.tagGuidance),
        seoGuidanceText: aiWritingStyleTextBinding(\.seoGuidance),
        preferredTerminologyText: aiWritingStyleTerminologyBinding(\.preferredTerminology),
        avoidedExpressionsText: aiWritingStyleTerminologyBinding(\.avoidedExpressions),
        exemplarArticleIDs: aiWritingStyleExemplarBinding,
        eligibleArticles: writingStyleArticles,
        initialPreview: writingStylePreview,
        isExtracting: isWritingStyleExtractionRunning,
        generatePreview: generateWritingStylePreview,
        applyPreview: applyWritingStylePreview,
        discardPreview: discardWritingStylePreview,
        currentActionMessage: currentActionMessage
      )
    }
    .formStyle(.grouped)
    .scrollIndicators(.hidden)
    .padding(WorkbenchSpacing.content)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("site-ai-settings")
  }

  private var activeProfile: SiteProfile {
    activeProfileBinding.wrappedValue
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
        profile.resolvedAIWritingStyle = style
        activeProfileBinding.wrappedValue = profile
      }
    )
  }

  private func aiWritingStyleTerminologyBinding(
    _ keyPath: WritableKeyPath<AIWritingStyleConfig, [String]>
  ) -> Binding<String> {
    Binding(
      get: {
        activeProfileBinding.wrappedValue.resolvedAIWritingStyle[keyPath: keyPath].joined(
          separator: "\n")
      },
      set: { value in
        var profile = activeProfileBinding.wrappedValue
        var style = profile.resolvedAIWritingStyle
        style.preset = .custom
        style[keyPath: keyPath] = value.components(separatedBy: .newlines)
        profile.resolvedAIWritingStyle = style
        activeProfileBinding.wrappedValue = profile
      }
    )
  }

  private var aiWritingStyleExemplarBinding: Binding<Set<UUID>> {
    Binding(
      get: { Set(activeProfileBinding.wrappedValue.resolvedAIWritingStyle.exemplarArticleIDs) },
      set: { ids in
        var profile = activeProfileBinding.wrappedValue
        var style = profile.resolvedAIWritingStyle
        style.exemplarArticleIDs = Array(ids).sorted { $0.uuidString < $1.uuidString }
        style.normalizeWhitespace()
        profile.resolvedAIWritingStyle = style
        activeProfileBinding.wrappedValue = profile
      }
    )
  }
}

private struct AIWritingStyleScopeNotice: View {
  let siteName: String

  var body: some View {
    Section {
      Label(
        "写作偏好只应用于当前站点“\(siteName)”。修改语气、受众和 SEO 指引不会改动共享的连接档案。",
        systemImage: "text.quote"
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      .accessibilityIdentifier("settings-ai-writing-style-current-site-scope")
      .settingsSubsectionAnchor(.aiWritingStyle)
    }
  }
}
