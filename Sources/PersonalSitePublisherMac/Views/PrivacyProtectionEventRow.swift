import PublishingWorkbenchCore
import SwiftUI

struct PrivacyProtectionEventRow: View {
  let event: PrivacyProtectionEvent

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack(alignment: .firstTextBaseline) {
        Label(event.kind.localizedDisplayName, systemImage: event.kind.systemImage)
          .font(.callout.weight(.medium))
        Spacer()
        Text(event.createdAt.formatted(date: .omitted, time: .shortened))
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Text(event.message)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(2)
    }
    .padding(.vertical, 4)
  }
}
