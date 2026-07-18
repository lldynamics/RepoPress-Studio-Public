import PublishingWorkbenchCore
import SwiftUI

struct InspectorScaffold<Content: View>: View {
  let title: String
  let subtitle: String
  let systemImage: String
  @ViewBuilder var content: Content

  var body: some View {
    VStack(spacing: 0) {
      HStack(alignment: .top, spacing: 10) {
        Image(systemName: systemImage)
          .foregroundStyle(.secondary)
          .frame(width: 18)

        VStack(alignment: .leading, spacing: 2) {
          Text(LocalizedStringKey(title))
            .font(.headline)
          Text(LocalizedStringKey(subtitle))
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }

        Spacer()
      }
      .padding(14)

      Divider()

      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .background(.bar)
  }
}

struct InspectorSection<Content: View>: View {
  let title: String
  @ViewBuilder var content: Content

  init(_ title: String, @ViewBuilder content: () -> Content) {
    self.title = title
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 9) {
      Text(LocalizedStringKey(title))
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
      content
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

struct InspectorStatRow: View {
  let title: String
  let value: String
  let systemImage: String

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: systemImage)
        .foregroundStyle(.secondary)
        .frame(width: 16)
      Text(LocalizedStringKey(title))
        .foregroundStyle(.secondary)
      Spacer()
      Text(value)
        .workbenchTruncatedIdentity(value)
    }
    .font(.caption)
  }
}

@ViewBuilder
func actionMessage(_ message: String?) -> some View {
  if let message, !message.isEmpty {
    Text(message)
      .font(.caption)
      .foregroundStyle(.secondary)
      .padding(8)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(WorkbenchBackgroundStyle.card, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control))
  }
}

extension PublishFileDiffStatus {
  var systemImage: String {
    switch self {
    case .added:
      return "plus.circle"
    case .modified:
      return "pencil.circle"
    case .deleted:
      return "trash.circle"
    case .unchanged:
      return "equal.circle"
    case .missingSource:
      return "photo.badge.exclamationmark"
    case .unsafePath:
      return "xmark.octagon"
    }
  }

  var color: Color {
    switch self {
    case .added:
      return WorkbenchTheme.success
    case .modified:
      return WorkbenchTheme.warning
    case .deleted:
      return WorkbenchTheme.risk
    case .unchanged:
      return .secondary
    case .missingSource, .unsafePath:
      return WorkbenchTheme.risk
    }
  }
}
