import PublishingWorkbenchCore
import SwiftUI

struct DefaultRuleSettingsView: View {
  let autoRunPreflightBinding: Binding<Bool>
  @Binding var scanRepositoryOnLaunch: Bool
  let activeProfileBinding: Binding<SiteProfile>
  let siteKindBinding: Binding<SiteKind>
  let healthDestination: SettingsConfigurationHealthDestination?
  let healthNavigationRequestID: UUID

  var body: some View {
    Form {
      DefaultRuleGeneralSection(
        autoRunPreflightBinding: autoRunPreflightBinding,
        scanRepositoryOnLaunch: $scanRepositoryOnLaunch
      )

      DisclosureGroup {
        DefaultRuleSiteSection(
          activeProfileBinding: activeProfileBinding,
          siteKindBinding: siteKindBinding
        )

        DefaultRulePathSection(
          activeProfileBinding: activeProfileBinding,
          shouldFocusPaths: healthDestination == .defaultRules,
          navigationRequestID: healthNavigationRequestID
        )
      } label: {
        Label("站点高级规则", systemImage: "gearshape.2")
      }
    }
    .formStyle(.grouped)
    .padding()
  }
}
