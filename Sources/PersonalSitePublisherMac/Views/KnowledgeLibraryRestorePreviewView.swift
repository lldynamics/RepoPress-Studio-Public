import AppKit
import PublishingWorkbenchCore
import SwiftUI

struct KnowledgeLibraryRestorePreviewView: View {
  @ObservedObject var knowledge: KnowledgeStore
  let preview: KnowledgeLibraryBackupPreview

  @Environment(\.dismiss) private var dismiss
  @State private var isRestoring = false

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack(alignment: .top, spacing: 12) {
        Image(systemName: "checkmark.shield.fill")
          .font(.system(size: 30))
          .foregroundStyle(WorkbenchTheme.success)
        VStack(alignment: .leading, spacing: 4) {
          Text("备份完整性校验通过")
            .font(.title2.weight(.semibold))
          Text(preview.backupURL.lastPathComponent)
            .font(.caption)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
        }
      }

      Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 9) {
        metadataRow("创建时间", value: preview.createdAt.formatted(date: .abbreviated, time: .shortened))
        metadataRow("应用版本", value: preview.applicationVersion)
        metadataRow("资料", value: "\(preview.documentCount) 条")
        metadataRow("文件夹", value: "\(preview.folderCount) 个")
        metadataRow("章节片段", value: "\(preview.chunkCount) 个")
        metadataRow(
          "备份大小",
          value: ByteCountFormatter.string(fromByteCount: preview.totalByteCount, countStyle: .file)
        )
      }

      if !preview.sampleTitles.isEmpty {
        VStack(alignment: .leading, spacing: 6) {
          Text("最近资料")
            .font(.headline)
          ForEach(preview.sampleTitles, id: \.self) { title in
            Label(title, systemImage: "doc.text")
              .workbenchTruncatedIdentity(title)
          }
        }
      }

      Label {
        Text("恢复会替换当前资料库并重新启动应用。当前资料库会先完整保留在恢复目录，可用于手动回退。")
      } icon: {
        Image(systemName: "exclamationmark.triangle.fill")
          .foregroundStyle(WorkbenchTheme.warning)
      }
      .padding(12)
      .background(WorkbenchTheme.warning.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))

      if let lastError = knowledge.lastError {
        Text(lastError)
          .font(.callout)
          .foregroundStyle(WorkbenchTheme.risk)
          .textSelection(.enabled)
      }

      HStack {
        Spacer()
        Button("取消") { dismiss() }
          .keyboardShortcut(.cancelAction)
          .disabled(isRestoring)
        Button("恢复并重新启动", role: .destructive) {
          stageRestoreAndRestart()
        }
        .keyboardShortcut(.defaultAction)
        .disabled(isRestoring)
      }
    }
    .padding(24)
    .frame(width: 520)
    .accessibilityIdentifier("knowledge-restore-preview")
  }

  private func metadataRow(_ label: LocalizedStringKey, value: String) -> some View {
    GridRow {
      Text(label)
        .foregroundStyle(.secondary)
      Text(value)
        .textSelection(.enabled)
    }
  }

  private func stageRestoreAndRestart() {
    isRestoring = true
    Task {
      let succeeded = await knowledge.stageRestore(from: preview.backupURL)
      isRestoring = false
      guard succeeded else { return }
      NSApp.terminate(nil)
    }
  }
}
