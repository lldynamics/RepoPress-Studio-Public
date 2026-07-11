import PublishingWorkbenchCore
import SwiftUI

struct PublishDrawerCard<Content: View>: View {
  let title: String
  let systemImage: String
  let content: Content

  init(
    title: String,
    systemImage: String,
    @ViewBuilder content: () -> Content
  ) {
    self.title = title
    self.systemImage = systemImage
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Label(title, systemImage: systemImage)
        .font(.callout.weight(.semibold))

      content

      Spacer(minLength: 0)
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .background(WorkbenchBackgroundStyle.card, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
    .accessibilityElement(children: .contain)
    .accessibilityLabel(title)
    .accessibilityHint("发布流程步骤内容")
  }
}

struct PublishDrawerStat: View {
  let title: String
  let value: String
  let systemImage: String
  let color: Color

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Label(title, systemImage: systemImage)
        .font(.caption2)
        .foregroundStyle(.secondary)
      Text(value)
        .font(.title3.weight(.semibold))
        .foregroundStyle(color)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(title)
    .accessibilityValue(value)
  }
}

struct PublishDrawerInfoRow: View {
  let title: String
  let value: String
  let systemImage: String

  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: systemImage)
        .foregroundStyle(.secondary)
        .frame(width: 16)
      Text(title)
        .foregroundStyle(.secondary)
      Spacer(minLength: 6)
      Text(value)
        .lineLimit(1)
    }
    .font(.caption)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(title)
    .accessibilityValue(value)
  }
}

extension PreflightSeverity {
  var publishDrawerSystemImage: String {
    switch self {
    case .error:
      return "xmark.octagon"
    case .warning:
      return "exclamationmark.triangle"
    case .info:
      return "checkmark.circle"
    }
  }

  var publishDrawerColor: Color {
    switch self {
    case .error:
      return WorkbenchTheme.risk
    case .warning:
      return WorkbenchTheme.warning
    case .info:
      return WorkbenchTheme.success
    }
  }
}

extension PublishFileDiffStatus {
  var publishDrawerSystemImage: String {
    switch self {
    case .added:
      return "plus.circle"
    case .modified:
      return "pencil.circle"
    case .unchanged:
      return "equal.circle"
    case .missingSource:
      return "photo.badge.exclamationmark"
    case .unsafePath:
      return "xmark.octagon"
    }
  }

  var publishDrawerColor: Color {
    switch self {
    case .added:
      return WorkbenchTheme.success
    case .modified:
      return WorkbenchTheme.warning
    case .unchanged:
      return .secondary
    case .missingSource, .unsafePath:
      return WorkbenchTheme.risk
    }
  }
}

struct PublishDrawerFlowStep: Identifiable {
  let id = UUID()
  let title: String
  let detail: String
  let systemImage: String
  let state: PublishDrawerFlowStepState
}

struct PublishDrawerFinalAction {
  let title: String
  let summary: String
  let systemImage: String
  let isDeploymentSuccessful: Bool
}

enum PublishDrawerFlowCard: CaseIterable, Hashable, Identifiable {
  case checks
  case diff
  case write
  case remote
  case deployment

  var id: Self { self }

  var title: String {
    switch self {
    case .checks:
      return "检查"
    case .diff:
      return "Diff"
    case .write:
      return "写入"
    case .remote:
      return "远端"
    case .deployment:
      return "部署"
    }
  }
}

enum PublishDrawerFlowStepState: Equatable {
  case complete
  case active
  case blocked
  case pending

  var color: Color {
    switch self {
    case .complete:
      return WorkbenchTheme.success
    case .active:
      return WorkbenchTheme.primary
    case .blocked:
      return WorkbenchTheme.risk
    case .pending:
      return .secondary
    }
  }

  var connectorColor: Color {
    switch self {
    case .complete, .active:
      return color.opacity(0.75)
    case .blocked, .pending:
      return Color(nsColor: .separatorColor)
    }
  }

  var backgroundColor: Color {
    switch self {
    case .complete:
      return WorkbenchTheme.success.opacity(0.10)
    case .active:
      return WorkbenchTheme.primary.opacity(0.12)
    case .blocked:
      return WorkbenchTheme.risk.opacity(0.10)
    case .pending:
      return Color(nsColor: .controlBackgroundColor).opacity(0.65)
    }
  }

  var borderColor: Color {
    switch self {
    case .active:
      return WorkbenchTheme.primary.opacity(0.55)
    case .blocked:
      return WorkbenchTheme.risk.opacity(0.45)
    case .complete:
      return WorkbenchTheme.success.opacity(0.35)
    case .pending:
      return Color(nsColor: .separatorColor).opacity(0.45)
    }
  }
}
