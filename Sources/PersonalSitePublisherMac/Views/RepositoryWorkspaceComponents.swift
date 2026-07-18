import PublishingWorkbenchCore
import SwiftUI

struct PublishReadinessTile: View {
  let title: String
  let readiness: LocalPublishActionReadiness

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Label(title, systemImage: readiness.systemImage)
        .font(.caption)
        .foregroundStyle(.secondary)
      Text(readiness.localizedDisplayName)
        .font(.callout.weight(.semibold))
        .foregroundStyle(readiness.color)
        .lineLimit(1)
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(WorkbenchBackgroundStyle.control, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
  }
}

struct BatchPublishPlanRow: View {
  var item: BatchPublishPlanItem
  var select: () -> Void

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      Label(item.readiness.localizedDisplayName, systemImage: item.readiness.systemImage)
        .font(.caption.weight(.semibold))
        .foregroundStyle(readinessColor)
        .frame(width: 78, alignment: .leading)

      VStack(alignment: .leading, spacing: 4) {
        Text(item.draftTitle)
          .font(.callout.weight(.medium))
          .workbenchTruncatedIdentity(item.draftTitle)
        Text(item.markdownPath)
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
          .workbenchTruncatedIdentity(item.markdownPath)
      }

      Spacer()

      HStack(spacing: 10) {
        Label("\(item.changedFileCount)", systemImage: "doc.on.doc")
        Label("\(item.warningCount)", systemImage: "exclamationmark.triangle")
        Label("\(item.errorCount)", systemImage: "xmark.octagon")
      }
      .font(.caption)
      .foregroundStyle(.secondary)

      Button {
        select()
      } label: {
        Label("定位", systemImage: "arrow.right.circle")
      }
      .labelStyle(.iconOnly)
      .help("定位到文章")
      .accessibilityLabel("定位到文章")
      .accessibilityValue(item.draftTitle)
    }
  }

  private var readinessColor: Color {
    switch item.readiness {
    case .ready:
      return WorkbenchTheme.success
    case .needsReview:
      return WorkbenchTheme.warning
    case .blocked:
      return WorkbenchTheme.risk
    case .unchanged:
      return .secondary
    }
  }
}

extension LocalPublishActionReadiness {
  var color: Color {
    switch self {
    case .ready:
      return WorkbenchTheme.success
    case .needsReview:
      return WorkbenchTheme.warning
    case .blocked:
      return WorkbenchTheme.risk
    case .unchanged:
      return .secondary
    }
  }
}

extension RepositoryWorkspaceView {
  var repositoryMetricGridColumns: [GridItem] {
    [GridItem(.adaptive(minimum: 132, maximum: 220), spacing: 10)]
  }
}
