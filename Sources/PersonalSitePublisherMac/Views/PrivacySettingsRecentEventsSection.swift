import AppKit
import PublishingWorkbenchCore
import SwiftUI

struct PrivacySettingsRecentEventsPlainContent: View {
  let events: [PrivacyProtectionEvent]
  var showsHeading = true

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if showsHeading {
        Label("最近隐私事件", systemImage: "clock")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
      }

      if events.isEmpty {
        Text("还没有锁定、解锁或设置变更记录。")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        ForEach(events.prefix(5)) { event in
          PrivacyProtectionEventRow(event: event)
        }
      }
    }
  }
}
