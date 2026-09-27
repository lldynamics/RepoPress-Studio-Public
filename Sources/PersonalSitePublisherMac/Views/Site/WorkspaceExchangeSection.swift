import PublishingBackupCore
import PublishingWorkbenchCore
import SwiftUI

@MainActor
struct WorkspaceExchangeSection: View {
  let store: WorkbenchStore

  @State private var workspaceExchangePreview: WorkspaceExchangePreview?
  @State private var isExchangingWorkspace = false
  @State private var operationMessage: String?
  @State private var operationError: String?

  var body: some View {
    GroupBox("站点与草稿交换") {
      VStack(alignment: .leading, spacing: 8) {
        Text("在设备之间导出或导入站点配置、文章草稿和附件。导入会先预览，确认后作为新草稿写入。")
          .font(.callout)
          .fixedSize(horizontal: false, vertical: true)

        Text("此处不包含私人笔记。笔记请在资料库的“笔记同步与备份”中管理。")
          .font(.footnote)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)

        HStack {
          Button("导出站点与草稿…", systemImage: "square.and.arrow.up") {
            exportWorkspaceExchange()
          }
          Button("导入站点与草稿…", systemImage: "square.and.arrow.down") {
            previewWorkspaceExchangeImport()
          }
        }
        .disabled(isExchangingWorkspace)

        if isExchangingWorkspace {
          ProgressView {
            Text("正在读取或写入跨端交换文件…")
          }
          .controlSize(.small)
        }

        if let operationMessage {
          AccessibleStatusMessage(message: operationMessage, severity: .success)
            .textSelection(.enabled)
        }
        if let operationError {
          AccessibleStatusMessage(message: operationError, severity: .error)
            .textSelection(.enabled)
        }
      }
    }
    .sheet(item: $workspaceExchangePreview) { preview in
      WorkspaceExchangeRestorePreviewSheet(preview: preview, store: store) { count in
        operationMessage = String(localized: "已将 \(count.formatted()) 篇文章作为新草稿导入。")
      }
    }
  }

  private func exportWorkspaceExchange() {
    guard !isExchangingWorkspace else { return }
    isExchangingWorkspace = true
    Task { @MainActor in
      defer { isExchangingWorkspace = false }
      guard let destinationURL = await WorkspaceExchangeFilePanel.chooseExportDestination() else {
        return
      }
      operationMessage = nil
      operationError = nil
      do {
        let data = try await store.makeWorkspaceExchangeData()
        try await Task.detached(priority: .utility) {
          try WorkspaceExchangeFilePanel.writePackageData(data, to: destinationURL)
        }.value
        operationMessage = String(
          localized: "跨端交换文件已写入所选位置：\(destinationURL.lastPathComponent)。"
        )
      } catch {
        operationError = error.localizedDescription
      }
    }
  }

  private func previewWorkspaceExchangeImport() {
    guard !isExchangingWorkspace else { return }
    isExchangingWorkspace = true
    Task { @MainActor in
      defer { isExchangingWorkspace = false }
      guard let sourceURL = await WorkspaceExchangeFilePanel.chooseImportSource() else { return }
      operationMessage = nil
      operationError = nil
      do {
        let data = try await Task.detached(priority: .utility) {
          try WorkspaceExchangeFilePanel.readPackageData(from: sourceURL)
        }.value
        workspaceExchangePreview = try await store.previewWorkspaceExchange(data: data)
      } catch {
        operationError = error.localizedDescription
      }
    }
  }
}
