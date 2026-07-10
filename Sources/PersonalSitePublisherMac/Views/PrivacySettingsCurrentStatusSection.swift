import AppKit
import PublishingWorkbenchCore
import SwiftUI

struct PrivacySettingsCurrentStatusSection: View {
  let status: PrivacyProtectionStatus
  let onLock: () -> Void
  let onUnlock: () -> Void

  var body: some View {
    Section("当前状态") {
      Label(
        status.title,
        systemImage: status.isLocked ? "lock.shield" : "lock.open"
      )
      .foregroundStyle(status.isLocked ? .orange : .secondary)

      Text(status.detail)
        .font(.caption)
        .foregroundStyle(.secondary)

      if !status.activeProtections.isEmpty {
        Text(status.activeProtections.joined(separator: " · "))
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      HStack {
        Button {
          onLock()
        } label: {
          Label("显示遮罩", systemImage: "eye.slash")
        }
        .disabled(status.isLocked)

        Button {
          onUnlock()
        } label: {
          Label("移除遮罩", systemImage: "eye")
        }
        .disabled(!status.isLocked)
      }
    }
  }
}
