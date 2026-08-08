import PublishingWorkbenchCore
import SwiftUI

struct DefaultRuleExpansionState: Equatable {
  var advancedFrontMatter = false
  var frontMatterPreview = false
  var pathRules = false

  mutating func revealPathRules(
    for navigationDestination: SettingsDestination?,
    legacyHealthDestination: SettingsConfigurationHealthDestination?
  ) {
    guard
      Self.shouldRevealPathRules(
        for: navigationDestination,
        legacyHealthDestination: legacyHealthDestination
      )
    else { return }
    pathRules = true
  }

  static func shouldRevealPathRules(
    for navigationDestination: SettingsDestination?,
    legacyHealthDestination: SettingsConfigurationHealthDestination?
  ) -> Bool {
    navigationDestination == .rules(.paths) || legacyHealthDestination == .defaultRules
  }
}

struct DefaultRuleSettingsView: View {
  let activeProfileBinding: Binding<SiteProfile>
  let siteKindBinding: Binding<SiteKind>
  let healthDestination: SettingsConfigurationHealthDestination?
  let healthNavigationRequestID: UUID
  let navigationDestination: SettingsDestination?
  let navigationRequestID: UUID
  @State private var expansionState = DefaultRuleExpansionState()

  var body: some View {
    Form {
      DefaultRuleSiteSection(
        activeProfileBinding: activeProfileBinding,
        siteKindBinding: siteKindBinding,
        expansionState: $expansionState
      )

      Section {
        DisclosureGroup(isExpanded: $expansionState.pathRules) {
          DefaultRulePathSection(
            activeProfileBinding: activeProfileBinding,
            shouldFocusPaths: shouldFocusPathRules,
            navigationRequestID: pathNavigationRequestID
          )
          .padding(.top, 6)

          Text("仅在站点目录结构不同时调整；默认值适用于当前站点类型。")
            .font(.caption)
            .foregroundStyle(.secondary)
        } label: {
          disclosureLabel(
            title: String(localized: "文件路径与模板"),
            detail: String(localized: "内容、资源和公开图片的目录及路径模板"),
            systemImage: "folder.badge.gearshape"
          )
        }
        .accessibilityIdentifier("default-rule-path-rules")
      }
    }
    .formStyle(.grouped)
    .scrollIndicators(.automatic)
    .padding(WorkbenchSpacing.content)
    .onAppear(perform: revealRequestedPathRules)
    .onChange(of: healthNavigationRequestID) { _, _ in
      revealRequestedPathRules()
    }
    .onChange(of: navigationRequestID) { _, _ in
      revealRequestedPathRules()
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("default-rule-settings")
  }

  private var shouldFocusPathRules: Bool {
    DefaultRuleExpansionState.shouldRevealPathRules(
      for: navigationDestination,
      legacyHealthDestination: healthDestination
    )
  }

  private var pathNavigationRequestID: UUID {
    healthDestination == .defaultRules ? healthNavigationRequestID : navigationRequestID
  }

  private func revealRequestedPathRules() {
    expansionState.revealPathRules(
      for: navigationDestination,
      legacyHealthDestination: healthDestination
    )
  }

  private func disclosureLabel(
    title: String,
    detail: String,
    systemImage: String
  ) -> some View {
    HStack(spacing: 10) {
      Image(systemName: systemImage)
        .foregroundStyle(WorkbenchTheme.navigationSelection)
        .frame(width: 20)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.body.weight(.medium))
        Text(detail)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .padding(.vertical, 3)
  }
}
