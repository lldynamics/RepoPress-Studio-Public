import PublishingWorkbenchCore
import SwiftUI

struct PublishDrawerActionChoice: View {
  let title: String
  let detail: String
  let status: String
  let systemImage: String
  let tint: Color
  let isEnabled: Bool
  let isPrimary: Bool
  let actionTitle: String
  let actionSystemImage: String
  let action: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Image(systemName: systemImage)
        .font(.title2)
        .foregroundStyle(tint)
        .accessibilityHidden(true)
      Text(title)
        .font(.headline)
      Text(detail)
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Label(status, systemImage: isEnabled ? "checkmark.circle" : "info.circle")
        .font(.caption)
        .foregroundStyle(isEnabled ? tint : .secondary)

      Spacer(minLength: 0)

      if isPrimary {
        Button(action: action) {
          Label(actionTitle, systemImage: actionSystemImage)
        }
        .workbenchProminentActionStyle()
        .keyboardShortcut(.defaultAction)
        .disabled(!isEnabled)
      } else {
        Button(action: action) {
          Label(actionTitle, systemImage: actionSystemImage)
        }
        .buttonStyle(.bordered)
        .disabled(!isEnabled)
      }
    }
    .padding(14)
    .frame(maxWidth: .infinity, minHeight: 190, alignment: .topLeading)
    .background(
      WorkbenchBackgroundStyle.subtle,
      in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
    )
    .overlay {
      RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
        .stroke(tint.opacity(isEnabled ? 0.35 : 0.15), lineWidth: 1)
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(title)
    .accessibilityValue(status)
  }
}

struct PublishDrawerFlowStepper: View {
  let steps: [PublishDrawerFlowStep]
  @Binding var selection: PublishDrawerFlowCard

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline) {
        Label("发布流程", systemImage: "point.topleft.down.curvedto.point.bottomright.up")
          .font(.caption.weight(.semibold))
        if let summaryStep {
          Label(summary, systemImage: summaryStep.systemImage)
            .font(.caption.weight(.medium))
            .foregroundStyle(summaryStep.state.color)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(summaryStep.state.backgroundColor, in: Capsule())
            .overlay {
              Capsule()
                .stroke(summaryStep.state.borderColor, lineWidth: 1)
            }
        }
        Spacer()
      }

      Picker("发布步骤", selection: $selection) {
        ForEach(PublishDrawerFlowCard.allCases) { step in
          Text(step.title).tag(step)
        }
      }
      .pickerStyle(.segmented)
      .tint(WorkbenchTheme.navigationSelection)
      .labelsHidden()
      .accessibilityLabel("发布步骤")
      .accessibilityValue(selection.title)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .background(.bar)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("发布流程")
    .accessibilityValue(summary)
  }

  private var summary: String {
    if let blocked = steps.first(where: { $0.state == .blocked }) {
      return "阻断在 \(blocked.title)：\(blocked.detail)"
    }
    if let active = steps.first(where: { $0.state == .active }) {
      return "当前步骤：\(active.title) · \(active.detail)"
    }
    return "发布流程已准备就绪"
  }

  private var summaryStep: PublishDrawerFlowStep? {
    steps.first(where: { $0.state == .blocked })
      ?? steps.first(where: { $0.state == .active })
      ?? steps.last(where: { $0.state == .complete })
      ?? steps.first
  }
}

struct PublishDrawerCheckResultsCard: View {
  let issues: [PreflightIssue]

  var body: some View {
    let blocking = issues.filter { $0.severity == .error }
    let warnings = issues.filter { $0.severity == .warning }

    PublishDrawerCard(title: "检查结果", systemImage: "checklist") {
      HStack(spacing: 8) {
        PublishDrawerStat(
          title: "阻断",
          value: "\(blocking.count)",
          systemImage: "xmark.octagon",
          color: blocking.isEmpty ? .secondary : WorkbenchTheme.risk
        )
        PublishDrawerStat(
          title: "警告",
          value: "\(warnings.count)",
          systemImage: "exclamationmark.triangle",
          color: warnings.isEmpty ? .secondary : WorkbenchTheme.warning
        )
      }

      if issues.isEmpty {
        Label("当前检查通过。", systemImage: "checkmark.circle")
          .font(.caption)
          .foregroundStyle(WorkbenchTheme.success)
      } else {
        VStack(alignment: .leading, spacing: 6) {
          ForEach(blocking) { issue in
            PublishDrawerIssueRow(issue: issue)
          }

          if !warnings.isEmpty {
            DisclosureGroup {
              VStack(alignment: .leading, spacing: 6) {
                ForEach(warnings) { issue in
                  PublishDrawerIssueRow(issue: issue)
                }
              }
              .padding(.top, 4)
            } label: {
              Label("警告（\(warnings.count)）", systemImage: "exclamationmark.triangle")
                .font(.caption.weight(.medium))
                .foregroundStyle(WorkbenchTheme.warning)
            }
          }
        }
      }
    }
  }
}

struct PublishDrawerIssueRow: View {
  let issue: PreflightIssue

  var body: some View {
    HStack(alignment: .top, spacing: 6) {
      Image(systemName: issue.severity.publishDrawerSystemImage)
        .foregroundStyle(issue.severity.publishDrawerColor)
        .frame(width: 14)
      VStack(alignment: .leading, spacing: 2) {
        Text(issue.title)
          .font(.workbenchItemTitle)
        Text(issue.message)
          .font(.workbenchSupporting)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}
