import PublishingWorkbenchCore
import SwiftUI

struct PrivacySettingsCurrentStatusSection: View {
  let status: PrivacyProtectionStatus
  let subsectionAnchor: SettingsSubsection?

  init(
    status: PrivacyProtectionStatus,
    subsectionAnchor: SettingsSubsection? = nil
  ) {
    self.status = status
    self.subsectionAnchor = subsectionAnchor
  }

  var body: some View {
    Section {
      Label(
        status.title,
        systemImage: "shield"
      )
      .foregroundStyle(Color.secondary)

      Text(status.detail)
        .font(.workbenchSupporting)
        .foregroundStyle(.secondary)

      if !status.activeProtections.isEmpty {
        Text(status.activeProtections.joined(separator: " · "))
          .font(.workbenchSupporting)
          .foregroundStyle(.secondary)
      }
    } header: {
      Text(String(localized: "当前保护状态"))
        .settingsSubsectionAnchor(subsectionAnchor)
    }
  }
}
