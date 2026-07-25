import AppKit
import PublishingWorkbenchCore
import SwiftUI

struct PrivacySettingsCurrentStatusSection: View {
  let status: PrivacyProtectionStatus
  let onLock: () -> Void
  let onUnlock: () -> Void

  var body: some View {
    Section(String(localized: "锁定状态")) {
      Label(
        status.title,
        systemImage: status.isLocked ? "lock.shield" : "lock.open"
      )
      .foregroundStyle(status.isLocked ? WorkbenchTheme.warning : Color.secondary)

      Text(status.detail)
        .font(.workbenchSupporting)
        .foregroundStyle(.secondary)

      if !status.activeProtections.isEmpty {
        Text(status.activeProtections.joined(separator: " · "))
          .font(.workbenchSupporting)
          .foregroundStyle(.secondary)
      }

      HStack {
        Button {
          onLock()
        } label: {
          Label(String(localized: "立即锁定软件"), systemImage: "lock.fill")
        }
        .workbenchProminentActionStyle(tint: WorkbenchTheme.warningActionFill)
        .disabled(status.isLocked)

        Button {
          onUnlock()
        } label: {
          Label("返回工作台", systemImage: "eye")
        }
        .buttonStyle(.bordered)
        .disabled(!status.isLocked)
      }
    }
  }
}
