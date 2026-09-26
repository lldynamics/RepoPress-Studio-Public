import SwiftUI

@MainActor
struct SettingsConfigurationStatusView: View {
  let context: SettingsContext
  var body: some View {
    GeometryReader { geometry in
      let contentWidth = min(
        1_100,
        max(0, geometry.size.width - 2 * WorkbenchSpacing.content)
      )
      ScrollView {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.section) {
          SettingsTaskShortcutsView(selectDestination: context.selectSettingsDestination)
            .settingsSubsectionAnchor(.configurationTasks)

          SettingsConfigurationHealthCard(
            profile: context.store.activeProfile,
            aiProviderConfig: context.store.aiProviderConfig(for: context.store.activeProfile),
            repositoryTokenAvailability: context.store.repositoryTokenAvailability,
            aiTokenAvailability: context.store.ai.tokenAvailability,
            selectDestination: context.selectConfigurationHealthDestination,
            isEmbedded: true
          )
          .padding(WorkbenchSpacing.content)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
          )
          .overlay {
            RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
              .strokeBorder(Color.primary.opacity(0.08))
          }
          .settingsSubsectionAnchor(.configurationReadiness)
        }
        .frame(width: contentWidth, alignment: .leading)
        .padding(WorkbenchSpacing.content)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("configuration-status-settings")
  }

}
