import AppKit
import PublishingWorkbenchCore
import SwiftUI

struct WorkspaceBackupRestorePreviewView: View {
  let preview: WorkspaceBackupPreview
  let stageWorkspaceBackupRestore: @MainActor (URL) async -> Bool

  @Environment(\.dismiss) private var dismiss
  @State private var isRestoring = false
  @State private var isCompatibilityConfirmationPresented = false

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack(alignment: .top, spacing: 12) {
        Image(systemName: "checkmark.shield.fill")
          .font(.system(size: 30))
          .foregroundStyle(WorkbenchTheme.success)
        VStack(alignment: .leading, spacing: 4) {
          Text("工作区备份完整性校验通过")
            .font(.title2.weight(.semibold))
          Text(preview.backupURL.lastPathComponent)
            .font(.caption)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
        }
      }

      Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 9) {
        metadataRow(
          String(localized: "创建时间"),
          value: preview.createdAt.formatted(date: .abbreviated, time: .shortened)
        )
        metadataRow(String(localized: "应用版本"), value: preview.applicationVersion)
        metadataRow(String(localized: "归档格式"), value: "v\(preview.formatVersion)")
        metadataRow(String(localized: "站点配置"), value: preview.profileCount.formatted())
        metadataRow(String(localized: "草稿"), value: preview.draftCount.formatted())
        metadataRow(String(localized: "历史版本"), value: preview.draftVersionCount.formatted())
        metadataRow(String(localized: "发布记录"), value: preview.releaseRecordCount.formatted())
        metadataRow(String(localized: "归档文件"), value: preview.fileCount.formatted())
        metadataRow(
          String(localized: "备份大小"),
          value: ByteCountFormatter.string(fromByteCount: preview.totalByteCount, countStyle: .file)
        )
      }

      VStack(alignment: .leading, spacing: 8) {
        Text("包含内容")
          .font(.headline)
        ForEach(preview.components, id: \.component) { component in
          Label {
            Text(componentSummary(component))
          } icon: {
            Image(systemName: systemImage(for: component.component))
          }
        }
      }

      Label {
        Text(apiKeyNotice)
      } icon: {
        Image(systemName: preview.includesAPIKeys ? "xmark.octagon.fill" : "lock.shield.fill")
          .foregroundStyle(preview.includesAPIKeys ? WorkbenchTheme.risk : WorkbenchTheme.success)
      }
      .padding(12)
      .background(
        (preview.includesAPIKeys ? WorkbenchTheme.risk : WorkbenchTheme.success).opacity(0.1),
        in: RoundedRectangle(cornerRadius: 10)
      )

      if preview.unresolvedAttachmentCount > 0 {
        Label(
          unresolvedAttachmentMessage,
          systemImage: "exclamationmark.triangle.fill"
        )
        .foregroundStyle(WorkbenchTheme.warning)
        .fixedSize(horizontal: false, vertical: true)
      }

      Label {
        Text(restoreImpactMessage)
      } icon: {
        Image(systemName: "exclamationmark.triangle.fill")
          .foregroundStyle(WorkbenchTheme.warning)
      }
      .padding(12)
      .background(WorkbenchTheme.warning.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))

      if preview.compatibility.requiresConfirmation {
        Label {
          Text(compatibilityMessage)
            .fixedSize(horizontal: false, vertical: true)
        } icon: {
          Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(WorkbenchTheme.warning)
        }
        .padding(12)
        .background(WorkbenchTheme.warning.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityIdentifier("workspace-backup-compatibility-warning")
      }

      HStack {
        Spacer()
        Button("取消") { dismiss() }
          .keyboardShortcut(.cancelAction)
          .disabled(isRestoring)
        Button(String(localized: "恢复并重新启动"), role: .destructive) {
          requestRestore()
        }
        .keyboardShortcut(.defaultAction)
        .disabled(isRestoring || preview.includesAPIKeys)
      }
    }
    .padding(24)
    .frame(width: 640)
    .accessibilityIdentifier("workspace-backup-restore-preview")
    .alert(String(localized: "版本兼容性提示"), isPresented: $isCompatibilityConfirmationPresented) {
      Button(String(localized: "仍然恢复"), role: .destructive) {
        stageRestoreAndRestart()
      }
      Button("取消", role: .cancel) {}
    } message: {
      Text(compatibilityMessage)
    }
  }

  private func metadataRow(_ label: String, value: String) -> some View {
    GridRow {
      Text(label)
        .foregroundStyle(.secondary)
      Text(value)
        .textSelection(.enabled)
    }
  }

  private func systemImage(for component: WorkspaceBackupComponent) -> String {
    switch component {
    case .workbenchState:
      return "square.and.pencil"
    case .draftAttachments:
      return "paperclip"
    case .knowledgeLibrary:
      return "books.vertical"
    case .rssReader:
      return "dot.radiowaves.left.and.right"
    }
  }

  private func componentSummary(_ component: WorkspaceBackupComponentSummary) -> String {
    String(
      format: String(localized: "%@ · %@ 个文件 · %@"),
      component.component.localizedDisplayName,
      component.fileCount.formatted(),
      ByteCountFormatter.string(fromByteCount: component.byteCount, countStyle: .file)
    )
  }

  private var apiKeyNotice: String {
    preview.includesAPIKeys
      ? String(localized: "此备份声明包含 API Key，应用不会导入。")
      : String(localized: "默认不包含 API Key；受限本地配置、系统钥匙串和本次会话中的 Key 都不会进入备份，跨机器恢复后需重新配置。")
  }

  private var restoreImpactMessage: String {
    if preview.components.contains(where: { $0.component == .rssReader }) {
      return String(
        localized: "恢复会替换当前工作台、资料库、RSS 和应用内附件，并重新启动应用。当前数据会先保留在恢复目录，可用于手动回退。"
      )
    }
    return String(
      localized: "这是旧版备份：恢复会替换当前工作台、资料库和应用内附件，但会保留现有 RSS 数据。当前数据会先保留在恢复目录。"
    )
  }

  private var unresolvedAttachmentMessage: String {
    String(
      format: String(
        localized: "有 %@ 个附件没有可复制的源文件；其元数据会保留，源文件需从原站点或仓库重新获取。"
      ),
      preview.unresolvedAttachmentCount.formatted()
    )
  }

  private var compatibilityMessage: String {
    switch preview.compatibility {
    case .compatible:
      return String(localized: "此备份与当前应用版本兼容。")
    case .createdByOlderApplication:
      return String(
        format: String(
          localized: "此备份由较旧版本创建（归档版本 %@）。应用会按当前格式迁移数据，恢复前请确认内容预览。"
        ),
        preview.applicationVersion
      )
    case .createdByNewerApplication:
      return String(
        format: String(
          localized: "此备份由较新版本创建（归档版本 %@），当前版本可能无法完整识别全部字段。建议先升级应用，再恢复此备份。"
        ),
        preview.applicationVersion
      )
    case .unknownApplicationVersion:
      return String(localized: "无法可靠比较归档与当前应用版本，但清单、快照、资料库和文件校验均已通过。确认要继续恢复吗？")
    }
  }

  private func requestRestore() {
    if preview.compatibility.requiresConfirmation {
      isCompatibilityConfirmationPresented = true
    } else {
      stageRestoreAndRestart()
    }
  }

  private func stageRestoreAndRestart() {
    isRestoring = true
    Task {
      let succeeded = await stageWorkspaceBackupRestore(preview.backupURL)
      isRestoring = false
      guard succeeded else { return }
      NSApp.terminate(nil)
    }
  }
}
