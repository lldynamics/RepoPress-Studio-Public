import PublishingWorkbenchCore
import SwiftUI

struct DefaultRuleSettingsView: View {
  @Binding var defaultShowsInspector: Bool
  let autoRunPreflightBinding: Binding<Bool>
  @Binding var scanRepositoryOnLaunch: Bool
  let activeProfileBinding: Binding<SiteProfile>
  let siteKindBinding: Binding<SiteKind>

  var body: some View {
    Form {
      DefaultRuleGeneralSection(
        defaultShowsInspector: $defaultShowsInspector,
        autoRunPreflightBinding: autoRunPreflightBinding,
        scanRepositoryOnLaunch: $scanRepositoryOnLaunch
      )

      DefaultRuleSiteSection(
        activeProfileBinding: activeProfileBinding,
        siteKindBinding: siteKindBinding
      )

      DefaultRulePathSection(
        activeProfileBinding: activeProfileBinding
      )
    }
    .formStyle(.grouped)
    .padding()
  }
}
