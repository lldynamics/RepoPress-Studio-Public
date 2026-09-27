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
  @State private var isSnapshotBackupPresented = false
  @AppStorage("knowledgeNoteICloudSyncEnabled") private var iCloudSyncEnabled = false
  @AppStorage("knowledgeNoteICloudAutoBackupEnabled") private var automaticICloudBackupEnabled =
    false
  @AppStorage("knowledgeNoteICloudSnapshotLastError") private var automaticSnapshotError = ""

  private var selectedNoteIDs: Set<UUID> {
    let noteIDs = Set(knowledge.documents.filter { $0.kind == .note }.map(\.id))
    return selectedDocumentIDs.intersection(noteIDs)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 4) {
          Text("笔记同步与备份")
            .font(.title2.weight(.semibold))
          Text("在 Mac、iPhone 和 iPad 之间接续笔记。")
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button("完成") { dismiss() }
          .keyboardShortcut(.cancelAction)
          .disabled(isWorking)
      }

      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          syncSection
          manualBackupSection
          if isWorking { ProgressView("正在处理笔记包…") }
          if let resultMessage {
            Label(resultMessage, systemImage: "checkmark.circle.fill")
              .foregroundStyle(.green)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .padding(24)
    .frame(minWidth: 620, idealWidth: 680, minHeight: 400, idealHeight: 460)
    .interactiveDismissDisabled(isWorking)
    .sheet(item: $preview) { value in
      KnowledgeNoteImportPreviewSheet(
        knowledge: knowledge,
        preview: value,
        isSnapshotRestore: false,
        onImported: { resultMessage = $0 }
      )
    }
    .sheet(isPresented: $isSnapshotBackupPresented) {
      KnowledgeNoteSnapshotBackupSheet(knowledge: knowledge)
    }
    .onAppear {
      if iCloudSyncEnabled { Task { await knowledge.startNoteCloudSync() } }
    }
    .task {
      while !Task.isCancelled {
        await knowledge.refreshNoteCloudSyncStatus()
        do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
      }
    }
    .onChange(of: iCloudSyncEnabled) { _, enabled in
      Task {
        if enabled {
          await knowledge.startNoteCloudSync()
        } else {
          await knowledge.stopNoteCloudSync()
        }
      }
    }
    .alert(
      "笔记包操作失败",
      isPresented: Binding(
        get: { errorMessage != nil },
        set: { if !$0 { errorMessage = nil } }
      )
    ) {
      Button("好", role: .cancel) {}
    } message: {
      Text(errorMessage ?? "")
    }
    .accessibilityIdentifier("knowledge-note-transfer")
  }

  private var syncSection: some View {
    GroupBox("iCloud 笔记同步") {
      VStack(alignment: .leading, spacing: 10) {
        Toggle("同步笔记与附件到 iCloud", isOn: $iCloudSyncEnabled)
          .accessibilityIdentifier("knowledge-note-cloud-sync")
        Text("在各设备上登录同一 iCloud 账号，并开启笔记同步。")
          .font(.footnote)
          .foregroundStyle(.secondary)
        Text(syncStatusDescription)
          .font(.footnote)
          .foregroundStyle(syncStatusIsFailure ? .red : .secondary)
          .fixedSize(horizontal: false, vertical: true)
        if iCloudSyncEnabled {
          HStack {
            Button("立即同步") { Task { await knowledge.refreshNoteCloudSync() } }
            if knowledge.noteCloudSyncStatus == .accountChangeNeedsReview {
              Button("确认切换账号并开始同步") {
                Task { await knowledge.confirmNoteCloudAccountChangeAndStart() }
              }
              .workbenchProminentActionStyle()
            }
            if knowledge.noteCloudSyncStatus == .remoteZoneDeletedNeedsRecovery {
              Button("确认重建云端资料区") {
                Task { await knowledge.confirmNoteCloudZoneRecoveryAndStart() }
              }
              .workbenchProminentActionStyle()
            }
          }
          ForEach(
            knowledge.noteCloudSyncErrors.sorted(by: { $0.key.uuidString < $1.key.uuidString }),
            id: \.key
          ) { entry in
            Label(
              "笔记 \(entry.key.uuidString.prefix(8))：\(entry.value)",
              systemImage: "exclamationmark.icloud.fill"
            )
            .font(.footnote)
            .foregroundStyle(.red)
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(8)
    }
  }

  private var manualBackupSection: some View {
    GroupBox("手动备份") {
      VStack(alignment: .leading, spacing: 10) {
        if selectedNoteIDs.isEmpty {
          Text("导出全部本地笔记")
        } else {
          Text("导出所选的 \(selectedNoteIDs.count) 条笔记")
        }
        Text("导出的 .rpnotes 文件可在另一台设备导入，也可作为离线备份。")
          .font(.footnote)
          .foregroundStyle(.secondary)
        HStack {
          Button("导出笔记文件…", systemImage: "square.and.arrow.up") { exportNotes() }
            .accessibilityIdentifier("knowledge-note-export")
          Menu("导入与恢复…") {
            Button("导入笔记文件…", systemImage: "square.and.arrow.down") { importNotes() }
            Divider()
            Button("版本备份与恢复…", systemImage: "clock.arrow.circlepath") {
              isSnapshotBackupPresented = true
            }
          }
          .fixedSize()
          .accessibilityIdentifier("knowledge-note-recovery")
        }
        .disabled(isWorking)
        Text("导入前会预览；内容冲突时保留副本，不覆盖原笔记。")
          .font(.footnote)
          .foregroundStyle(.secondary)
        if automaticICloudBackupEnabled {
          Text("自动版本备份已开启，可在“导入与恢复”中管理。")
            .font(.footnote)
            .foregroundStyle(.secondary)
          if !automaticSnapshotError.isEmpty {
            Label("自动备份失败：\(automaticSnapshotError)", systemImage: "exclamationmark.icloud.fill")
              .font(.footnote)
              .foregroundStyle(.red)
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(8)
    }
  }

  private var syncStatusDescription: String {
    switch knowledge.noteCloudSyncStatus {
    case .disabled: String(localized: "同步已关闭。")
    case .checkingAccount: String(localized: "正在检查 iCloud 账号…")
    case .waitingForAccount: String(localized: "请先登录 iCloud 账号。")
    case .accountChangeNeedsReview:
      String(localized: "检测到 iCloud 账号已切换；同步已暂停，确认后才会绑定新账号。")
    case .syncing: String(localized: "iCloud 同步已启动，变更会在网络可用时继续处理。")
    case .conflict: String(localized: "存在同步冲突，副本已保留在本机。")
    case .remoteZoneDeletedNeedsRecovery:
      String(localized: "云端笔记资料区已删除；确认后会重建并重新上传本机笔记。")
    case .failed(let message): String(localized: "同步失败：\(message)")
    }
  }

  private var syncStatusIsFailure: Bool {
    if case .failed = knowledge.noteCloudSyncStatus { return true }
    return knowledge.noteCloudSyncStatus == .accountChangeNeedsReview
      || knowledge.noteCloudSyncStatus == .remoteZoneDeletedNeedsRecovery
  }

  private func exportNotes() {
    guard !isWorking else { return }
    isWorking = true
    Task {
      defer { isWorking = false }
      do {
        let package = try await knowledge.exportNotePackage(selectedIDs: selectedNoteIDs)
        guard !package.notes.isEmpty else { throw NoteTransferError.noNotes }
        guard let destination = await NotesPackageSelectionPanel.chooseExportDestination() else {
          return
        }
        try await Task.detached(priority: .userInitiated) {
          let wrapper = try RPNotesPackageCodec.encode(package)
          try wrapper.write(to: destination, options: .atomic, originalContentsURL: nil)
        }.value
        resultMessage = String(localized: "已导出 \(package.notes.count) 条笔记。")
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  private func importNotes() {
    guard !isWorking else { return }
    isWorking = true
    Task {
      defer { isWorking = false }
      guard let source = await NotesPackageSelectionPanel.chooseImportPackage() else { return }
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

}

private enum NoteTransferError: LocalizedError {
  case noNotes

  var errorDescription: String? {
    String(localized: "本机没有可导出的笔记。")
  }
}
