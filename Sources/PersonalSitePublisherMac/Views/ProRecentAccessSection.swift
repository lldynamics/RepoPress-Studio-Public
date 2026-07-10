import PublishingWorkbenchCore
import SwiftUI

struct ProRecentAccessSection: View {
  let events: [MonetizationAccessEvent]

  var body: some View {
    Section("最近使用记录") {
      ProRecentAccessPlainContent(events: events, showsHeading: false)
    }
  }
}

struct ProRecentAccessPlainContent: View {
  let events: [MonetizationAccessEvent]
  var showsHeading = true

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if showsHeading {
        Label("最近使用记录", systemImage: "clock")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
      }

      if events.isEmpty {
        Text("还没有 AI、线上发布或批量发布的免费版/Pro 边界记录。")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        ForEach(events.prefix(6)) { event in
          ProAccessEventRow(event: event)
        }
      }
    }
  }
}
