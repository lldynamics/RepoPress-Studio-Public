import PublishingWorkbenchCore
import SwiftUI

struct DefaultRuleSettingsView: View {
  let autoRunPreflightBinding: Binding<Bool>
  @Binding var scanRepositoryOnLaunch: Bool
  let activeProfileBinding: Binding<SiteProfile>
  let siteKindBinding: Binding<SiteKind>
  let healthDestination: SettingsConfigurationHealthDestination?
  let healthNavigationRequestID: UUID
  @State private var showsPathRules = false

  var body: some View {
    Form {
      DefaultRuleGeneralSection(
        autoRunPreflightBinding: autoRunPreflightBinding,
        scanRepositoryOnLaunch: $scanRepositoryOnLaunch
      )

      DefaultRuleSiteSection(
        activeProfileBinding: activeProfileBinding,
        siteKindBinding: siteKindBinding
      )

      Section {
        DisclosureGroup(isExpanded: $showsPathRules) {
          DefaultRulePathSection(
            activeProfileBinding: activeProfileBinding,
            shouldFocusPaths: healthDestination == .defaultRules,
            navigationRequestID: healthNavigationRequestID
          )
        } label: {
          Label("文件路径与模板", systemImage: "folder.badge.gearshape")
        }
      } footer: {
        Text("仅在站点目录结构不同时调整；默认值适用于当前站点类型。")
      }
    }
    .formStyle(.grouped)
    .scrollIndicators(.automatic)
    .padding(WorkbenchSpacing.content)
    .onAppear(perform: revealRequestedPathRules)
    .onChange(of: healthNavigationRequestID) { _, _ in
      revealRequestedPathRules()
    }
    .accessibilityIdentifier("default-rule-settings")
  }

  private func revealRequestedPathRules() {
    guard healthDestination == .defaultRules else { return }
    showsPathRules = true
  }
}
