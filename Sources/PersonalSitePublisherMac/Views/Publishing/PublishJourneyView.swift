import SwiftUI

struct PublishJourneyView: View {
  let presentation: PublishJourneyPresentation
  let primaryAction: () -> Void
  let settingsAction: (PublishJourneySettingsTarget) -> Void
  let releaseHistoryAction: () -> Void

  var body: some View {
    PublishDrawerCard(title: presentation.title, systemImage: "paperplane.fill") {
      VStack(alignment: .leading, spacing: 12) {
        Text(presentation.detail)
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)

        if let target = presentation.settingsTarget,
          let title = presentation.settingsActionTitle
        {
          Button {
            settingsAction(target)
          } label: {
            Label(title, systemImage: target.systemImage)
          }
          .buttonStyle(.bordered)
          .accessibilityIdentifier("publish-journey-open-settings")
        }

        VStack(alignment: .leading, spacing: 8) {
          ForEach(presentation.steps) { step in
            PublishJourneyStepRow(step: step)
          }
        }

        if let message = presentation.configurationMessage {
          AccessibleStatusMessage(message: message, severity: .warning)
        }

        HStack(spacing: 8) {
          Button {
            releaseHistoryAction()
          } label: {
            Label("查看发布记录", systemImage: "clock.arrow.circlepath")
          }
          .buttonStyle(.bordered)
          .accessibilityIdentifier("publish-journey-open-history")

          Spacer(minLength: 8)

          Button(action: primaryAction) {
            Label(presentation.primaryActionTitle, systemImage: "paperplane.fill")
          }
          .workbenchProminentActionStyle()
          .keyboardShortcut(.defaultAction)
          .disabled(!presentation.isPrimaryActionEnabled)
          .help(presentation.primaryActionHint)
          .accessibilityIdentifier("publish-drawer-action-publish-current")
          .accessibilityHint(presentation.primaryActionHint)
        }
      }
    }
    .accessibilityIdentifier("publish-journey")
  }
}

private struct PublishJourneyStepRow: View {
  let step: PublishJourneyStep

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      statusIcon
        .frame(width: 18, height: 18)
        .padding(.top, 1)

      VStack(alignment: .leading, spacing: 2) {
        Text(step.title)
          .font(.callout.weight(.semibold))
        Text(step.detail)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      Spacer(minLength: 8)

      Text(step.status.accessibilityTitle)
        .font(.caption.weight(.medium))
        .foregroundStyle(step.status.color)
    }
    .padding(9)
    .background(
      step.status.color.opacity(step.status == .active ? 0.10 : 0.05),
      in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
    )
    .accessibilityElement(children: .ignore)
    .accessibilityIdentifier("publish-journey-step-\(step.id)")
    .accessibilityLabel(step.title)
    .accessibilityValue("\(step.status.accessibilityTitle)，\(step.detail)")
  }

  @ViewBuilder
  private var statusIcon: some View {
    if step.status == .active {
      ProgressView()
        .controlSize(.small)
        .accessibilityHidden(true)
    } else {
      Image(systemName: step.status.systemImage)
        .foregroundStyle(step.status.color)
        .accessibilityHidden(true)
    }
  }
}

extension PublishJourneyStepStatus {
  fileprivate var accessibilityTitle: String {
    switch self {
    case .upcoming: return String(localized: "未开始")
    case .active: return String(localized: "进行中")
    case .complete: return String(localized: "已完成")
    case .blocked: return String(localized: "已阻断")
    }
  }

  fileprivate var systemImage: String {
    switch self {
    case .upcoming: return "circle"
    case .active: return "clock.arrow.circlepath"
    case .complete: return "checkmark.circle.fill"
    case .blocked: return "xmark.octagon.fill"
    }
  }

  fileprivate var color: Color {
    switch self {
    case .upcoming: return .secondary
    case .active: return WorkbenchTheme.progress
    case .complete: return WorkbenchTheme.success
    case .blocked: return WorkbenchTheme.risk
    }
  }
}

extension PublishJourneySettingsTarget {
  fileprivate var systemImage: String {
    switch self {
    case .repository: return "shippingbox"
    case .deployment: return "rocket"
    }
  }
}
