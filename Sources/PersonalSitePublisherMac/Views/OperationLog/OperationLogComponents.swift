import SwiftUI

struct OperationLogRow: View {
  let entry: OperationLogPresentation.Entry

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: entry.systemImage)
        .foregroundStyle(outcomeColor)
        .frame(width: 16)

      VStack(alignment: .leading, spacing: 3) {
        Text(entry.title)
          .lineLimit(1)
        if let targetLabel = entry.targetLabel {
          Text(targetLabel)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        HStack(spacing: 5) {
          Text(entry.outcomeDisplayName)
            .foregroundStyle(outcomeColor)
          Text(entry.occurredAt, format: .dateTime.hour().minute())
        }
        .font(.workbenchMetadata)
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(entry.title)
    .accessibilityValue(operationLogAccessibilityValue(entry))
  }

  private var outcomeColor: Color {
    operationLogOutcomeColor(entry.outcome)
  }
}

struct OperationLogDetailView: View {
  let entry: OperationLogPresentation.Entry
  let openSyncWorkspace: () -> Void

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        HStack(alignment: .top, spacing: 12) {
          Image(systemName: entry.systemImage)
            .font(.title2)
            .foregroundStyle(operationLogOutcomeColor(entry.outcome))
            .frame(width: 32)
          VStack(alignment: .leading, spacing: 4) {
            Text(entry.title)
              .font(.title2.weight(.semibold))
              .textSelection(.enabled)
            if let targetLabel = entry.targetLabel {
              Text(targetLabel)
                .foregroundStyle(.secondary)
            }
          }
          Spacer(minLength: 0)
          Text(entry.outcomeDisplayName)
            .font(.callout.weight(.medium))
            .foregroundStyle(operationLogOutcomeColor(entry.outcome))
        }

        detailSection("活动摘要") {
          Text(entry.summary)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
        }

        detailSection("记录详情") {
          Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 12) {
            detailRow("类别", value: entry.categoryDisplayName)
            detailRow("结果", value: entry.outcomeDisplayName)
            detailRow("执行方", value: entry.actorDisplayName)
            detailRow(
              "时间",
              value: entry.occurredAt.formatted(.dateTime.year().month().day().hour().minute()))
          }
        }

        if entry.category == .publishing {
          detailSection("发布相关记录") {
            VStack(alignment: .leading, spacing: 10) {
              Text(entry.sourceLabel)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
              Button(action: openSyncWorkspace) {
                Label("前往同步工作区", systemImage: "arrow.right.circle")
              }
              .workbenchProminentActionStyle()
            }
          }
        }
      }
      .padding(24)
      .frame(maxWidth: 880, alignment: .leading)
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("operation-log-detail")
  }

  private func detailSection<Content: View>(
    _ title: LocalizedStringKey,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title)
        .font(.headline)
      content()
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.quaternary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
  }

  private func detailRow(_ title: LocalizedStringKey, value: String) -> some View {
    GridRow {
      Text(title)
        .foregroundStyle(.secondary)
      Text(value)
        .textSelection(.enabled)
    }
  }
}

private func operationLogOutcomeColor(_ outcome: OperationLogPresentation.Outcome) -> Color {
  switch outcome {
  case .succeeded, .recorded, .observed:
    return .green
  case .partial:
    return .orange
  case .failed:
    return .red
  case .cancelled:
    return .secondary
  }
}

private func operationLogAccessibilityValue(_ entry: OperationLogPresentation.Entry) -> String {
  let target = entry.targetLabel.map { " · \($0)" } ?? ""
  return
    "\(entry.outcomeDisplayName) · \(entry.occurredAt.formatted(.dateTime.hour().minute()))\(target)"
}
