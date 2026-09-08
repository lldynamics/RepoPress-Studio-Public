import AppKit
import PublishingWorkbenchCore
import SwiftUI

struct PrivacySettingsCurrentStatusSection: View {
  let status: PrivacyProtectionStatus
  let onQuickHide: () -> Void
  let subsectionAnchor: SettingsSubsection?

  init(
    status: PrivacyProtectionStatus,
    onQuickHide: @escaping () -> Void,
    subsectionAnchor: SettingsSubsection? = nil
  ) {
    self.status = status
    self.onQuickHide = onQuickHide
    self.subsectionAnchor = subsectionAnchor
  }

  var body: some View {
    Section {
      Label(
        status.title,
        systemImage: status.isQuickHideActive ? "eye.slash" : "eye"
      )
      .foregroundStyle(status.isQuickHideActive ? WorkbenchTheme.warning : Color.secondary)

      Text(status.detail)
        .font(.workbenchSupporting)
        .foregroundStyle(.secondary)

      if !status.activeProtections.isEmpty {
        Text(status.activeProtections.joined(separator: " · "))
          .font(.workbenchSupporting)
          .foregroundStyle(.secondary)
      }

      Button {
        onQuickHide()
      } label: {
        Label(String(localized: "立即快速隐藏"), systemImage: "eye.slash")
      }
      .workbenchProminentActionStyle(tint: WorkbenchTheme.warningActionFill)
      .disabled(status.isQuickHideActive)
    } header: {
      Text(String(localized: "快速隐藏状态"))
        .settingsSubsectionAnchor(subsectionAnchor)
    }
  }
}
