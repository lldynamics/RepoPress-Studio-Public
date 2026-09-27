import PublishingKnowledgeCore
import SwiftUI

struct KnowledgeNoteSnapshotBackupSheet: View {
  @ObservedObject var knowledge: KnowledgeStore
  @Environment(\.dismiss) private var dismiss

  @AppStorage("knowledgeNoteSnapshotLastSuccessAt") private var lastSnapshotSuccessAt = 0.0
  @AppStorage("knowledgeNoteSnapshotLastSuccessLocation") private var lastSnapshotSuccessLocation =
    ""
  @AppStorage("knowledgeNoteSnapshotLastError") private var lastSnapshotError = ""
  @AppStorage("knowledgeNoteICloudAutoBackupEnabled") private var automaticICloudBackupEnabled =
    false
  @AppStorage("knowledgeNoteICloudSnapshotLastSuccessAt") private var automaticSnapshotSuccessAt =
    0.0
  @AppStorage("knowledgeNoteICloudSnapshotLastURL") private var automaticSnapshotLastURL = ""
  @AppStorage("knowledgeNoteICloudSnapshotUploadStatus") private var automaticSnapshotUploadStatus =
    ""
  @AppStorage("knowledgeNoteICloudSnapshotLastError") private var automaticSnapshotError = ""

  @State private var isWorking = false
  @State private var errorMessage: String?
  @State private var resultMessage: String?
  @State private var preview: KnowledgeNotePackagePreview?
  @State private var isSnapshotBrowserExpanded = false
  @State private var availableSnapshots: [KnowledgeNoteSnapshotInfo] = []

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        HStack {
          VStack(alignment: .leading, spacing: 4) {
            Text("笔记版本备份")
              .font(.title2.weight(.semibold))
            Text("保存可用于恢复历史版本的独立笔记快照。")
              .foregroundStyle(.secondary)
          }
          Spacer()
          Button("完成") { dismiss() }
            .keyboardShortcut(.cancelAction)
            .disabled(isWorking)
        }

        GroupBox("自动备份") {
          VStack(alignment: .leading, spacing: 8) {
            Toggle("启用自动 iCloud 版本备份", isOn: $automaticICloudBackupEnabled)
            Text("笔记有变化时每天最多创建一份快照；内容未变会跳过。旧版本不会自动清理。")
              .font(.footnote)
              .foregroundStyle(.secondary)
            Text("自动备份用于恢复历史版本，不会替换本机当前笔记。")
              .font(.footnote)
              .foregroundStyle(.secondary)
          }
          .padding(8)
        }

        GroupBox("创建快照") {
          VStack(alignment: .leading, spacing: 8) {
            Text("将全部本地笔记和附件保存为独立的 .rpnotes 快照。")
            HStack {
              Spacer()
              Button("立即保存到 iCloud") { createICloudSnapshotNow() }
                .disabled(isWorking)
              Button("创建快照…") { createSnapshot() }
                .disabled(isWorking)
            }
          }
          .padding(8)
        }

        GroupBox("恢复历史版本") {
          VStack(alignment: .leading, spacing: 8) {
            Text("选择快照后先预览新增、相同和冲突笔记，再恢复历史版本。原笔记会保留。")
              .foregroundStyle(.secondary)
            HStack {
              Button("选择快照…") { restoreSnapshot() }
                .disabled(isWorking)
              Button(
                isSnapshotBrowserExpanded
                  ? String(localized: "收起 iCloud 快照") : String(localized: "浏览已有 iCloud 快照…")
              ) {
                if isSnapshotBrowserExpanded {
                  isSnapshotBrowserExpanded = false
                } else {
                  loadICloudSnapshots()
                }
              }
              .disabled(isWorking)
              Spacer()
              if !automaticSnapshotLastURL.isEmpty {
                Button("检查上传状态") { refreshAutomaticUploadStatus() }
              }
            }
            if isSnapshotBrowserExpanded { snapshotBrowser }
          }
          .padding(8)
        }

        if automaticSnapshotSuccessAt > 0 {
          Label(
            "最近写入 iCloud 容器：\(Date(timeIntervalSince1970: automaticSnapshotSuccessAt), style: .date) \(Date(timeIntervalSince1970: automaticSnapshotSuccessAt), style: .time)",
            systemImage: "checkmark.icloud"
          )
          .foregroundStyle(.secondary)
          Text(automaticUploadStatusDescription)
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        if !automaticSnapshotError.isEmpty {
          Label("自动备份失败：\(automaticSnapshotError)", systemImage: "exclamationmark.icloud.fill")
            .font(.footnote)
            .foregroundStyle(.red)
        }
        if lastSnapshotSuccessAt > 0 {
          Label {
            Text(
              "最近成功：\(lastSnapshotSuccessLocation) · \(Date(timeIntervalSince1970: lastSnapshotSuccessAt), style: .date) \(Date(timeIntervalSince1970: lastSnapshotSuccessAt), style: .time)"
            )
          } icon: {
            Image(systemName: "checkmark.circle.fill")
          }
          .foregroundStyle(.secondary)
        } else {
          Text("尚未创建快照。选择 iCloud Drive 文件夹即可保存到 iCloud Drive；也可选择本地文件夹。")
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        if !lastSnapshotError.isEmpty {
          Label("上次备份失败：\(lastSnapshotError)", systemImage: "exclamationmark.icloud.fill")
            .font(.footnote)
            .foregroundStyle(.red)
        }
        if isWorking { ProgressView("正在处理笔记快照…") }
        if let resultMessage {
          Label(resultMessage, systemImage: "checkmark.circle.fill")
            .foregroundStyle(.green)
        }
      }
      .padding(24)
    }
    .frame(minWidth: 620, minHeight: 590)
    .interactiveDismissDisabled(isWorking)
    .accessibilityIdentifier("knowledge-note-snapshot-backup")
    .sheet(item: $preview) { value in
      KnowledgeNoteImportPreviewSheet(
        knowledge: knowledge,
        preview: value,
        isSnapshotRestore: true
      ) { message in
        resultMessage = message
      }
    }
    .onAppear {
      refreshAutomaticUploadStatus()
      if automaticICloudBackupEnabled { scheduleAutomaticSnapshot() }
    }
    .onChange(of: automaticICloudBackupEnabled) { _, enabled in
      if enabled { scheduleAutomaticSnapshot() }
    }
    .alert(
      "笔记快照操作失败",
      isPresented: Binding(
        get: { errorMessage != nil },
        set: { if !$0 { errorMessage = nil } }
      )
    ) {
      Button("好", role: .cancel) {}
    } message: {
      Text(errorMessage ?? "")
    }
  }

  private var snapshotBrowser: some View {
    VStack(alignment: .leading, spacing: 8) {
      if availableSnapshots.isEmpty {
        ContentUnavailableView(
          "没有可用快照",
          systemImage: "icloud.slash",
          description: Text("启用自动备份并保存一条笔记后，快照会显示在这里。")
        )
      } else {
        ForEach(availableSnapshots) { snapshot in
          Button {
            previewICloudSnapshot(snapshot)
          } label: {
            VStack(alignment: .leading, spacing: 3) {
              Text(snapshot.url.deletingPathExtension().lastPathComponent)
                .lineLimit(1)
              Text(snapshot.createdAt, style: .date)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
          .buttonStyle(.plain)
        }
      }
    }
    .padding(.top, 4)
  }

  private var automaticUploadStatusDescription: String {
    switch KnowledgeNoteSnapshotUploadStatus(rawValue: automaticSnapshotUploadStatus) {
    case .uploaded:
      return String(localized: "iCloud 已确认这份快照上传完成。")
    case .uploading:
      return String(localized: "快照已写入本机 iCloud 容器，iCloud 正在上传。")
    case .waitingForUpload:
      return String(localized: "快照已写入本机 iCloud 容器，尚未确认上传完成。")
    case .unavailable, nil:
      return String(localized: "快照已写入本机容器，当前无法读取 iCloud 上传状态。")
    }
  }

  private func createSnapshot() {
    guard !isWorking else { return }
    isWorking = true
    Task {
      guard let directory = await NotesPackageSelectionPanel.chooseSnapshotDirectory() else {
        isWorking = false
        return
      }
      let didStartAccess = directory.startAccessingSecurityScopedResource()
      defer {
        if didStartAccess { directory.stopAccessingSecurityScopedResource() }
        isWorking = false
      }
      do {
        let package = try await knowledge.exportNotePackage(selectedIDs: [])
        guard !package.notes.isEmpty else { throw NoteSnapshotError.noNotes }
        let snapshotResult = try await Task.detached(priority: .userInitiated) {
          let url = try KnowledgeNoteSnapshotBackupService.createSnapshot(package, in: directory)
          let appBackupRoot = try? KnowledgeNoteSnapshotBackupService.iCloudNotesBackupDirectory()
          let selectedPath = directory.resolvingSymlinksInPath().standardizedFileURL.path
          let appBackupPath = appBackupRoot?.resolvingSymlinksInPath().standardizedFileURL.path
          var signature: String?
          if let rootPath = appBackupPath,
            selectedPath == rootPath || selectedPath.hasPrefix(rootPath + "/")
          {
            signature = try? KnowledgeNoteSnapshotBackupService.contentSignature(for: package.notes)
          }
          return (url, signature)
        }.value
        let now = Date().timeIntervalSince1970
        lastSnapshotSuccessAt = now
        lastSnapshotSuccessLocation = Self.locationLabel(for: directory)
        lastSnapshotError = ""
        resultMessage = String(
          localized: "已在\(lastSnapshotSuccessLocation)创建包含 \(package.notes.count) 条笔记的快照。")
        if let signature = snapshotResult.1 {
          UserDefaults.standard.set(now, forKey: "knowledgeNoteICloudSnapshotLastSuccessAt")
          UserDefaults.standard.set(
            snapshotResult.0.path, forKey: "knowledgeNoteICloudSnapshotLastURL")
          UserDefaults.standard.set(signature, forKey: "knowledgeNoteICloudSnapshotContentHash")
          UserDefaults.standard.set(
            KnowledgeNoteSnapshotUploadStatus.waitingForUpload.rawValue,
            forKey: "knowledgeNoteICloudSnapshotUploadStatus")
          automaticSnapshotSuccessAt = now
          automaticSnapshotLastURL = snapshotResult.0.path
          automaticSnapshotUploadStatus =
            KnowledgeNoteSnapshotUploadStatus.waitingForUpload.rawValue
        }
      } catch {
        lastSnapshotError = error.localizedDescription
        errorMessage = error.localizedDescription
      }
    }
  }

  private func createICloudSnapshotNow() {
    guard !isWorking else { return }
    isWorking = true
    Task {
      defer { isWorking = false }
      do {
        let package = try await knowledge.exportNotePackage(selectedIDs: [])
        let creation = try await Task.detached(priority: .userInitiated) {
          try KnowledgeNoteSnapshotBackupService.createICloudSnapshot(package)
        }.value
        let now = Date().timeIntervalSince1970
        UserDefaults.standard.set(now, forKey: "knowledgeNoteICloudSnapshotLastSuccessAt")
        UserDefaults.standard.set(creation.url.path, forKey: "knowledgeNoteICloudSnapshotLastURL")
        UserDefaults.standard.set(
          creation.contentSignature, forKey: "knowledgeNoteICloudSnapshotContentHash")
        UserDefaults.standard.set(
          KnowledgeNoteSnapshotUploadStatus.waitingForUpload.rawValue,
          forKey: "knowledgeNoteICloudSnapshotUploadStatus")
        UserDefaults.standard.removeObject(forKey: "knowledgeNoteICloudSnapshotLastError")
        automaticSnapshotSuccessAt = now
        automaticSnapshotLastURL = creation.url.path
        automaticSnapshotUploadStatus = KnowledgeNoteSnapshotUploadStatus.waitingForUpload.rawValue
        automaticSnapshotError = ""
        lastSnapshotSuccessAt = now
        lastSnapshotSuccessLocation = String(localized: "iCloud 备份")
        lastSnapshotError = ""
        resultMessage = String(localized: "已保存 \(package.notes.count) 条笔记到 iCloud 容器。上传状态待确认。")
      } catch {
        automaticSnapshotError = error.localizedDescription
        errorMessage = error.localizedDescription
      }
    }
  }

  private func restoreSnapshot() {
    guard !isWorking else { return }
    isWorking = true
    Task {
      guard let source = await NotesPackageSelectionPanel.chooseSnapshotPackage() else {
        isWorking = false
        return
      }
      let didStartAccess = source.startAccessingSecurityScopedResource()
      defer {
        if didStartAccess { source.stopAccessingSecurityScopedResource() }
        isWorking = false
      }
      do {
        let package = try await Task.detached(priority: .userInitiated) {
          try KnowledgeNoteSnapshotBackupService.readSnapshot(at: source)
        }.value
        preview = try await knowledge.previewNotePackage(package)
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  private func loadICloudSnapshots() {
    guard !isWorking else { return }
    isWorking = true
    Task {
      defer { isWorking = false }
      do {
        let snapshots = try await Task.detached(priority: .utility) {
          let directory = try KnowledgeNoteSnapshotBackupService.iCloudNotesBackupDirectory()
          return try KnowledgeNoteSnapshotBackupService.snapshots(in: directory)
        }.value
        availableSnapshots = snapshots
        isSnapshotBrowserExpanded = true
      } catch {
        automaticSnapshotError = error.localizedDescription
        errorMessage = error.localizedDescription
      }
    }
  }

  private func previewICloudSnapshot(_ snapshot: KnowledgeNoteSnapshotInfo) {
    guard !isWorking else { return }
    isWorking = true
    Task {
      defer { isWorking = false }
      do {
        let package = try await Task.detached(priority: .userInitiated) {
          try KnowledgeNoteSnapshotBackupService.readSnapshot(at: snapshot.url)
        }.value
        preview = try await knowledge.previewNotePackage(package)
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  private func scheduleAutomaticSnapshot() {
    Task {
      do {
        _ = try await knowledge.createAutomaticNoteSnapshotIfDue()
      } catch {
        automaticSnapshotError = error.localizedDescription
        UserDefaults.standard.set(
          error.localizedDescription, forKey: "knowledgeNoteICloudSnapshotLastError")
      }
    }
  }

  private func refreshAutomaticUploadStatus() {
    guard !automaticSnapshotLastURL.isEmpty else { return }
    let snapshotPath = automaticSnapshotLastURL
    Task.detached(priority: .utility) {
      let status = KnowledgeNoteSnapshotBackupService.iCloudUploadStatus(at: snapshotPath)
      UserDefaults.standard.set(status.rawValue, forKey: "knowledgeNoteICloudSnapshotUploadStatus")
    }
  }

  private static func locationLabel(for directory: URL) -> String {
    let cloudDrive = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
      .standardizedFileURL.path
    let selectedPath = directory.standardizedFileURL.path
    guard selectedPath == cloudDrive || selectedPath.hasPrefix(cloudDrive + "/") else {
      return String(localized: "本地备份")
    }
    return String(localized: "iCloud 备份")
  }
}

private enum NoteSnapshotError: LocalizedError {
  case noNotes

  var errorDescription: String? { String(localized: "本机没有可导出的笔记。") }
}
