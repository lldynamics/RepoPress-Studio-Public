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
          Label("快速隐藏", systemImage: "eye.slash")
        }
        .disabled(status.isLocked)

        Button {
          onUnlock()
        } label: {
          Label("返回工作台", systemImage: "eye")
        }
        .disabled(!status.isLocked)
      }
    }
  }
}
