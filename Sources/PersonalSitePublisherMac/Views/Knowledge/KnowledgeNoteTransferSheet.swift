import PublishingKnowledgeCore
import SwiftUI

struct KnowledgeNoteTransferSheet: View {
  @ObservedObject var knowledge: KnowledgeStore
  let selectedDocumentIDs: Set<UUID>
  @Environment(\.dismiss) private var dismiss
  @State private var preview: KnowledgeNotePackagePreview?
  @State private var isWorking = false
  @State private var errorMessage: String?
  @State private var resultMessage: String?
  @State private var previewKind: PreviewKind = .packageImport
  @AppStorage("knowledgeNoteSnapshotLastSuccessAt") private var lastSnapshotSuccessAt = 0.0
  @AppStorage("knowledgeNoteSnapshotLastSuccessLocation") private var lastSnapshotSuccessLocation = ""
  @AppStorage("knowledgeNoteSnapshotLastError") private var lastSnapshotError = ""
  @AppStorage("knowledgeNoteICloudAutoBackupEnabled") private var automaticICloudBackupEnabled = false
  @AppStorage("knowledgeNoteICloudSnapshotLastSuccessAt") private var automaticSnapshotSuccessAt = 0.0
  @AppStorage("knowledgeNoteICloudSnapshotLastURL") private var automaticSnapshotLastURL = ""
  @AppStorage("knowledgeNoteICloudSnapshotUploadStatus") private var automaticSnapshotUploadStatus = ""
  @AppStorage("knowledgeNoteICloudSnapshotLastError") private var automaticSnapshotError = ""
  @AppStorage("knowledgeNoteICloudSyncEnabled") private var iCloudSyncEnabled = false
  @State private var isSnapshotBrowserPresented = false
  @State private var availableSnapshots: [KnowledgeNoteSnapshotInfo] = []

  private var selectedNoteIDs: Set<UUID> {
    let noteIDs = Set(knowledge.documents.filter { $0.kind == .note }.map(\.id))
    return selectedDocumentIDs.intersection(noteIDs)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        VStack(alignment: .leading, spacing: 4) {
          Text("笔记导入与导出")
            .font(.title2.weight(.semibold))
          Text("在 Mac 与 iPhone、iPad 之间手动交换本地笔记。")
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button("完成") { dismiss() }
      }

      GroupBox("导出") {
        HStack {
          Text(selectedNoteIDs.isEmpty ? "导出全部本地笔记" : "导出所选的 \(selectedNoteIDs.count) 条笔记")
          Spacer()
          Button("选择保存位置…") { exportNotes() }
            .disabled(isWorking)
        }
        .padding(8)
      }

      GroupBox("导入") {
        HStack {
          Text("先验证整个笔记包，再预览新增与冲突。")
          Spacer()
          Button("选择 .rpnotes 文件…") { importNotes() }
            .disabled(isWorking)
        }
        .padding(8)
      }

      GroupBox("笔记版本快照") {
        VStack(alignment: .leading, spacing: 8) {
          Toggle("启用自动 iCloud 版本备份", isOn: $automaticICloudBackupEnabled)
          Text("笔记有变化时每天最多创建一份快照；内容未变会跳过。旧版本不会自动清理。")
            .font(.footnote)
            .foregroundStyle(.secondary)
          HStack {
            Text("将全部本地笔记和附件保存为独立的 .rpnotes 快照。")
            Spacer()
            Button("立即保存到 iCloud") { createICloudSnapshotNow() }
              .disabled(isWorking)
            Button("创建快照…") { createSnapshot() }
              .disabled(isWorking)
          }
          HStack {
            Text("从快照恢复")
            Spacer()
            Button("选择快照…") { restoreSnapshot() }
              .disabled(isWorking)
          }
          HStack {
            Button("浏览 iCloud 快照…") { loadICloudSnapshots() }
              .disabled(isWorking)
            Spacer()
            if !automaticSnapshotLastURL.isEmpty {
              Button("检查上传状态") { refreshAutomaticUploadStatus() }
            }
          }
          ForEach(knowledge.noteCloudSyncErrors.sorted(by: { $0.key.uuidString < $1.key.uuidString }), id: \.key) { entry in
            Label("笔记 \(entry.key.uuidString.prefix(8))：\(entry.value)", systemImage: "exclamationmark.icloud.fill")
              .font(.footnote)
              .foregroundStyle(.red)
          }
          if automaticSnapshotSuccessAt > 0 {
            Label("最近写入 iCloud 容器：\(Date(timeIntervalSince1970: automaticSnapshotSuccessAt), style: .date) \(Date(timeIntervalSince1970: automaticSnapshotSuccessAt), style: .time)", systemImage: "checkmark.icloud")
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
              Text("最近成功：\(lastSnapshotSuccessLocation) · \(Date(timeIntervalSince1970: lastSnapshotSuccessAt), style: .date) \(Date(timeIntervalSince1970: lastSnapshotSuccessAt), style: .time)")
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
        }
        .padding(8)
      }

      GroupBox("iCloud 笔记同步") {
        VStack(alignment: .leading, spacing: 8) {
          Toggle("同步笔记与附件到 iCloud", isOn: $iCloudSyncEnabled)
          Text("首次启用会先读取 iCloud 现有笔记；账号切换和云端资料区重建需要你明确确认。")
            .font(.footnote)
            .foregroundStyle(.secondary)
          HStack {
            Text(syncStatusDescription)
              .font(.footnote)
              .foregroundStyle(syncStatusIsFailure ? .red : .secondary)
            Spacer()
            if iCloudSyncEnabled { Button("立即同步") { Task { await knowledge.refreshNoteCloudSync() } } }
            if knowledge.noteCloudSyncStatus == .accountChangeNeedsReview {
              Button("确认切换账号并开始同步") { Task { await knowledge.confirmNoteCloudAccountChangeAndStart() } }
              .workbenchProminentActionStyle()
            }
            if knowledge.noteCloudSyncStatus == .remoteZoneDeletedNeedsRecovery {
              Button("确认重建云端资料区") { Task { await knowledge.confirmNoteCloudZoneRecoveryAndStart() } }
              .workbenchProminentActionStyle()
            }
          }
        }
        .padding(8)
      }

      if isWorking { ProgressView("正在处理笔记包…") }
      if let resultMessage {
        Label(resultMessage, systemImage: "checkmark.circle.fill")
          .foregroundStyle(.green)
      }
      Text("导入只写入本机资料库；相同 ID 的不同内容只会作为副本保留，不会覆盖原笔记。")
        .font(.footnote)
        .foregroundStyle(.secondary)
      Spacer(minLength: 0)
    }
    .padding(24)
    .frame(minWidth: 620, minHeight: 590)
    .sheet(item: $preview) { value in
      importPreview(value)
    }
    .sheet(isPresented: $isSnapshotBrowserPresented) {
      snapshotBrowser
    }
    .onAppear {
      refreshAutomaticUploadStatus()
      if automaticICloudBackupEnabled { scheduleAutomaticSnapshot() }
      if iCloudSyncEnabled { Task { await knowledge.startNoteCloudSync() } }
    }
    .task {
      while !Task.isCancelled {
        await knowledge.refreshNoteCloudSyncStatus()
        do { try await Task.sleep(nanoseconds: 2_000_000_000) }
        catch { return }
      }
    }
    .onChange(of: automaticICloudBackupEnabled) { _, enabled in
      if enabled { scheduleAutomaticSnapshot() }
    }
    .onChange(of: iCloudSyncEnabled) { _, enabled in
      Task {
        if enabled { await knowledge.startNoteCloudSync() }
        else { await knowledge.stopNoteCloudSync() }
      }
    }
    .alert("笔记包操作失败", isPresented: Binding(
      get: { errorMessage != nil },
      set: { if !$0 { errorMessage = nil } }
    )) {
      Button("好", role: .cancel) {}
    } message: {
      Text(errorMessage ?? "")
    }
  }

  private func exportNotes() {
    guard !isWorking else { return }
    isWorking = true
    Task {
      defer { isWorking = false }
      do {
        let package = try await knowledge.exportNotePackage(selectedIDs: selectedNoteIDs)
        guard !package.notes.isEmpty else { throw NoteTransferError.noNotes }
        guard let destination = NotesPackageSelectionPanel.chooseExportDestination() else { return }
        try await Task.detached(priority: .userInitiated) {
          let wrapper = try RPNotesPackageCodec.encode(package)
          try wrapper.write(to: destination, options: .atomic, originalContentsURL: nil)
        }.value
        resultMessage = "已导出 \(package.notes.count) 条笔记。"
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  private func importNotes() {
    guard !isWorking else { return }
    guard let source = NotesPackageSelectionPanel.chooseImportPackage() else { return }
    isWorking = true
    previewKind = .packageImport
    Task {
      defer { isWorking = false }
      do {
        let package = try await Task.detached(priority: .userInitiated) {
          let wrapper = try FileWrapper(url: source, options: .immediate)
          return try RPNotesPackageCodec.decode(wrapper)
        }.value
        preview = try await knowledge.previewNotePackage(package)
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  private func createSnapshot() {
    guard !isWorking, let directory = NotesPackageSelectionPanel.chooseSnapshotDirectory() else { return }
    let didStartAccess = directory.startAccessingSecurityScopedResource()
    isWorking = true
    Task {
      defer {
        if didStartAccess { directory.stopAccessingSecurityScopedResource() }
        isWorking = false
      }
      do {
        let package = try await knowledge.exportNotePackage(selectedIDs: [])
        guard !package.notes.isEmpty else { throw NoteTransferError.noNotes }
        let snapshotResult = try await Task.detached(priority: .userInitiated) {
          let url = try KnowledgeNoteSnapshotBackupService.createSnapshot(package, in: directory)
          let appBackupRoot = try? KnowledgeNoteSnapshotBackupService.iCloudNotesBackupDirectory()
          let selectedPath = directory.resolvingSymlinksInPath().standardizedFileURL.path
          let appBackupPath = appBackupRoot?.resolvingSymlinksInPath().standardizedFileURL.path
          var signature: String?
          if let rootPath = appBackupPath,
             selectedPath == rootPath || selectedPath.hasPrefix(rootPath + "/") {
            signature = try? KnowledgeNoteSnapshotBackupService.contentSignature(for: package.notes)
          }
          return (url, signature)
        }.value
        let now = Date().timeIntervalSince1970
        lastSnapshotSuccessAt = now
        lastSnapshotSuccessLocation = Self.locationLabel(for: directory)
        lastSnapshotError = ""
        resultMessage = "已在\(lastSnapshotSuccessLocation)创建包含 \(package.notes.count) 条笔记的快照。"
        if let signature = snapshotResult.1 {
          UserDefaults.standard.set(now, forKey: "knowledgeNoteICloudSnapshotLastSuccessAt")
          UserDefaults.standard.set(snapshotResult.0.path, forKey: "knowledgeNoteICloudSnapshotLastURL")
          UserDefaults.standard.set(signature, forKey: "knowledgeNoteICloudSnapshotContentHash")
          UserDefaults.standard.set(
            KnowledgeNoteSnapshotUploadStatus.waitingForUpload.rawValue,
            forKey: "knowledgeNoteICloudSnapshotUploadStatus"
          )
          automaticSnapshotSuccessAt = now
          automaticSnapshotLastURL = snapshotResult.0.path
          automaticSnapshotUploadStatus = KnowledgeNoteSnapshotUploadStatus.waitingForUpload.rawValue
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
        UserDefaults.standard.set(creation.contentSignature, forKey: "knowledgeNoteICloudSnapshotContentHash")
        UserDefaults.standard.set(
          KnowledgeNoteSnapshotUploadStatus.waitingForUpload.rawValue,
          forKey: "knowledgeNoteICloudSnapshotUploadStatus"
        )
        UserDefaults.standard.removeObject(forKey: "knowledgeNoteICloudSnapshotLastError")
        automaticSnapshotSuccessAt = now
        automaticSnapshotLastURL = creation.url.path
        automaticSnapshotUploadStatus = KnowledgeNoteSnapshotUploadStatus.waitingForUpload.rawValue
        automaticSnapshotError = ""
        lastSnapshotSuccessAt = now
        lastSnapshotSuccessLocation = "iCloud 备份"
        lastSnapshotError = ""
        resultMessage = "已保存 \(package.notes.count) 条笔记到 iCloud 容器。上传状态待确认。"
      } catch {
        automaticSnapshotError = error.localizedDescription
        errorMessage = error.localizedDescription
      }
    }
  }

  private func restoreSnapshot() {
    guard !isWorking, let source = NotesPackageSelectionPanel.chooseSnapshotPackage() else { return }
    let didStartAccess = source.startAccessingSecurityScopedResource()
    isWorking = true
    previewKind = .snapshotRestore
    Task {
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

  private var snapshotBrowser: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("iCloud 笔记快照")
          .font(.title3.weight(.semibold))
        Spacer()
        Button("完成") { isSnapshotBrowserPresented = false }
      }
      if availableSnapshots.isEmpty {
        ContentUnavailableView("没有可用快照", systemImage: "icloud.slash", description: Text("启用自动备份并保存一条笔记后，快照会显示在这里。"))
      } else {
        List(availableSnapshots) { snapshot in
          Button {
            isSnapshotBrowserPresented = false
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
    .padding(20)
    .frame(minWidth: 560, minHeight: 360)
  }

  private var automaticUploadStatusDescription: String {
    switch KnowledgeNoteSnapshotUploadStatus(rawValue: automaticSnapshotUploadStatus) {
    case .uploaded:
      return "iCloud 已确认这份快照上传完成。"
    case .uploading:
      return "快照已写入本机 iCloud 容器，iCloud 正在上传。"
    case .waitingForUpload:
      return "快照已写入本机 iCloud 容器，尚未确认上传完成。"
    case .unavailable, nil:
      return "快照已写入本机容器，当前无法读取 iCloud 上传状态。"
    }
  }

  private var syncStatusDescription: String {
    switch knowledge.noteCloudSyncStatus {
    case .disabled: "同步已关闭。"
    case .checkingAccount: "正在检查 iCloud 账号…"
    case .waitingForAccount: "请先登录 iCloud 账号。"
    case .accountChangeNeedsReview: "检测到 iCloud 账号已切换；同步已暂停，确认后才会绑定新账号。"
    case .syncing: "iCloud 同步已启动，变更会在网络可用时继续处理。"
    case .conflict: "存在同步冲突，副本已保留在本机。"
    case .remoteZoneDeletedNeedsRecovery: "云端笔记资料区已删除；确认后会重建并重新上传本机笔记。"
    case let .failed(message): "同步失败：\(message)"
    }
  }

  private var syncStatusIsFailure: Bool {
    if case .failed = knowledge.noteCloudSyncStatus { return true }
    return knowledge.noteCloudSyncStatus == .accountChangeNeedsReview || knowledge.noteCloudSyncStatus == .remoteZoneDeletedNeedsRecovery
  }

  private func scheduleAutomaticSnapshot() {
    Task {
      do {
        _ = try await knowledge.createAutomaticNoteSnapshotIfDue()
      } catch {
        automaticSnapshotError = error.localizedDescription
        UserDefaults.standard.set(error.localizedDescription, forKey: "knowledgeNoteICloudSnapshotLastError")
      }
    }
  }

  private func loadICloudSnapshots() {
    isWorking = true
    Task {
      defer { isWorking = false }
      do {
        let snapshots = try await Task.detached(priority: .utility) {
          let directory = try KnowledgeNoteSnapshotBackupService.iCloudNotesBackupDirectory()
          return try KnowledgeNoteSnapshotBackupService.snapshots(in: directory)
        }.value
        availableSnapshots = snapshots
        isSnapshotBrowserPresented = true
      } catch {
        automaticSnapshotError = error.localizedDescription
        errorMessage = error.localizedDescription
      }
    }
  }

  private func previewICloudSnapshot(_ snapshot: KnowledgeNoteSnapshotInfo) {
    guard !isWorking else { return }
    isWorking = true
    previewKind = .snapshotRestore
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

  private enum PreviewKind: Equatable {
    case packageImport
    case snapshotRestore
  }

  private func importPreview(_ value: KnowledgeNotePackagePreview) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(previewKind == .snapshotRestore ? "预览快照恢复" : "预览笔记导入")
        .font(.title3.weight(.semibold))
      HStack(spacing: 20) {
        Text("新增 \(value.newCount)")
        Text("相同跳过 \(value.identicalCount)")
        Text("内容冲突 \(value.conflictCount)")
        if value.blockedCount > 0 { Text("标识被其他资料占用 \(value.blockedCount)") }
      }
      if !value.blockedTitles.isEmpty {
        Text("以下资料与包内笔记使用相同标识，不能导入。请先处理这些资料。")
          .foregroundStyle(.red)
        ForEach(value.blockedTitles.indices, id: \.self) { index in
          Text(value.blockedTitles[index])
        }
      }
      if !value.conflictingTitles.isEmpty {
        Text("冲突笔记")
          .font(.headline)
        ScrollView {
          VStack(alignment: .leading) {
            ForEach(value.conflictingTitles.indices, id: \.self) { index in
              Text(value.conflictingTitles[index])
            }
          }
        }
        .frame(maxHeight: 160)
      }
      Text("冲突笔记将作为新副本导入，本机原笔记会保留。")
        .foregroundStyle(.secondary)
      HStack {
        Spacer()
        Button("取消") { preview = nil }
        Button(actionTitle(for: value)) {
          applyImport(value)
        }
        .workbenchProminentActionStyle()
        .disabled(isWorking || value.blockedCount > 0)
      }
    }
    .padding(24)
    .frame(minWidth: 480, minHeight: 220)
  }

  private func actionTitle(for value: KnowledgeNotePackagePreview) -> String {
    if previewKind == .snapshotRestore {
      return value.conflictCount == 0 ? "恢复快照" : "保留冲突副本并恢复"
    }
    return value.conflictCount == 0 ? "导入" : "保留两份并导入"
  }

  private func applyImport(_ value: KnowledgeNotePackagePreview) {
    guard !isWorking else { return }
    isWorking = true
    Task {
      defer { isWorking = false }
      do {
        let results = try await knowledge.importNotePackage(
          value.package,
          keepConflictingCopies: value.conflictCount > 0
        )
        let inserted = results.filter { if case .inserted = $0 { return true }; return false }.count
        let identical = results.filter { if case .skippedIdentical = $0 { return true }; return false }.count
        let copied = results.filter { if case .copied = $0 { return true }; return false }.count
        preview = nil
        resultMessage = "已新增 \(inserted) 条，保留副本 \(copied) 条，跳过相同 \(identical) 条。"
      } catch {
        preview = nil
        errorMessage = error.localizedDescription
      }
    }
  }
}

private enum NoteTransferError: LocalizedError {
  case noNotes

  var errorDescription: String? {
    "本机没有可导出的笔记。"
  }
}
