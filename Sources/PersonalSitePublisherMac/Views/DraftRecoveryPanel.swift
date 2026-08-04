import PublishingWorkbenchCore
import SwiftUI

struct DraftRecoveryPanel: View {
  @ObservedObject var store: WorkbenchStore
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      VStack(alignment: .leading, spacing: 4) {
        Text("发现未保存草稿")
          .font(.title3.weight(.semibold))
        Text("这些内容来自上次异常结束前的编辑缓冲区。恢复已有草稿时，如果当前内容已经变化，会自动创建恢复副本。")
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      if store.pendingDraftRecoveries.isEmpty {
        ContentUnavailableView(
          "没有待恢复草稿",
          systemImage: "checkmark.circle",
          description: Text("当前工作台没有可恢复的未保存编辑。")
        )
      } else {
        List(store.pendingDraftRecoveries) { record in
          DraftRecoveryRow(
            record: record,
            profileName: store.profiles.first(where: { $0.id == record.siteProfileID })?.name,
            restore: {
              _ = store.restoreDraftRecovery(record)
              if store.pendingDraftRecoveries.isEmpty {
                dismiss()
              }
            },
            discard: {
              store.discardDraftRecovery(record)
              if store.pendingDraftRecoveries.isEmpty {
                dismiss()
              }
            }
          )
        }
        .listStyle(.inset)
      }

      HStack {
        Spacer()
        Button("稍后处理") {
          dismiss()
        }
        .keyboardShortcut(.cancelAction)
      }
    }
    .padding(20)
    .frame(minWidth: 560, idealWidth: 640, minHeight: 360, idealHeight: 460)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("未保存草稿恢复")
  }
}

private struct DraftRecoveryRow: View {
  let record: DraftRecoveryRecord
  let profileName: String?
  let restore: () -> Void
  let discard: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(record.title)
          .font(.headline)
          .lineLimit(2)
        Spacer(minLength: 8)
        Text(record.capturedAt, style: .relative)
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      HStack(spacing: 8) {
        Label(profileName ?? String(localized: "未命名站点"), systemImage: "globe")
        if let repositoryPath = record.repositoryPath {
          Text(repositoryPath)
            .lineLimit(1)
            .truncationMode(.middle)
        }
      }
      .font(.caption)
      .foregroundStyle(.secondary)

      HStack {
        Button("恢复") {
          restore()
        }
        .workbenchProminentActionStyle()
        .accessibilityLabel(String(localized: "恢复 \(record.title)"))

        Button("忽略") {
          discard()
        }
        .buttonStyle(.bordered)
        .accessibilityLabel(String(localized: "忽略 \(record.title) 的恢复内容"))
      }
    }
    .padding(.vertical, 6)
  }
}
