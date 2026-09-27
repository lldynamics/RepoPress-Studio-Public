import PublishingKnowledgeCore
import SwiftUI

struct KnowledgeNoteImportPreviewSheet: View {
  @ObservedObject var knowledge: KnowledgeStore
  let preview: KnowledgeNotePackagePreview
  let isSnapshotRestore: Bool
  let onImported: (String) -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var isWorking = false
  @State private var errorMessage: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(isSnapshotRestore ? String(localized: "预览快照恢复") : String(localized: "预览笔记导入"))
        .font(.title3.weight(.semibold))

      HStack(spacing: 20) {
        Text("新增 \(preview.newCount)")
        Text("相同跳过 \(preview.identicalCount)")
        Text("内容冲突 \(preview.conflictCount)")
        if preview.blockedCount > 0 {
          Text("标识被其他资料占用 \(preview.blockedCount)")
        }
      }

      if !preview.blockedTitles.isEmpty {
        Text("以下资料与包内笔记使用相同标识，不能导入。请先处理这些资料。")
          .foregroundStyle(.red)
        ForEach(preview.blockedTitles.indices, id: \.self) { index in
          Text(preview.blockedTitles[index])
        }
      }

      if !preview.conflictingTitles.isEmpty {
        Text("冲突笔记")
          .font(.headline)
        ScrollView {
          VStack(alignment: .leading) {
            ForEach(preview.conflictingTitles.indices, id: \.self) { index in
              Text(preview.conflictingTitles[index])
            }
          }
        }
        .frame(maxHeight: 160)
      }

      Text("冲突笔记将作为新副本导入，本机原笔记会保留。")
        .foregroundStyle(.secondary)

      HStack {
        Spacer()
        Button("取消") { dismiss() }
          .keyboardShortcut(.cancelAction)
          .disabled(isWorking)
        Button(actionTitle) { applyImport() }
          .workbenchProminentActionStyle()
          .disabled(isWorking || preview.blockedCount > 0)
      }
    }
    .padding(24)
    .frame(minWidth: 480, minHeight: 220)
    .interactiveDismissDisabled(isWorking)
    .overlay {
      if isWorking {
        ProgressView("正在导入笔记包…")
          .padding()
      }
    }
    .alert(
      "笔记包操作失败",
      isPresented: Binding(
        get: { errorMessage != nil },
        set: { if !$0 { errorMessage = nil } }
      )
    ) {
      Button("重试") { applyImport() }
      Button("取消", role: .cancel) {}
    } message: {
      Text(errorMessage ?? "")
    }
  }

  private var actionTitle: String {
    if isSnapshotRestore {
      return preview.conflictCount == 0 ? String(localized: "恢复快照") : String(localized: "保留冲突副本并恢复")
    }
    return preview.conflictCount == 0 ? String(localized: "导入") : String(localized: "保留两份并导入")
  }

  private func applyImport() {
    guard !isWorking, preview.blockedCount == 0 else { return }
    isWorking = true
    errorMessage = nil
    Task {
      defer { isWorking = false }
      do {
        let results = try await knowledge.importNotePackage(
          preview.package,
          keepConflictingCopies: preview.conflictCount > 0
        )
        let inserted = results.filter {
          if case .inserted = $0 { return true }
          return false
        }.count
        let identical = results.filter {
          if case .skippedIdentical = $0 { return true }
          return false
        }.count
        let copied = results.filter {
          if case .copied = $0 { return true }
          return false
        }.count
        onImported(String(localized: "已新增 \(inserted) 条，保留副本 \(copied) 条，跳过相同 \(identical) 条。"))
        dismiss()
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }
}
