import PublishingWorkbenchCore
import SwiftUI

struct KnowledgeRecycleBinView: View {
  @Environment(\.dismiss) private var dismiss
  @ObservedObject var knowledge: KnowledgeStore
  @State private var selection = Set<UUID>()
  @State private var isPermanentDeleteConfirmationPresented = false

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        Label("资料回收站", systemImage: "trash")
          .font(.headline)
        Text("\(knowledge.recycledDocuments.count) 条")
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
        Spacer()
      }
      .padding(14)

      Divider()

      if knowledge.recycledDocuments.isEmpty {
        EmptyStateView(
          title: "回收站为空",
          message: "从资料库移除的内容会先保留在这里，只有永久删除才会清理本地副本。",
          systemImage: "trash",
          density: .fullPage
        )
      } else {
        List(selection: $selection) {
          ForEach(knowledge.recycledDocuments) { recycled in
            recycledRow(recycled)
              .tag(recycled.id)
              .contextMenu {
                Button("恢复") { restore([recycled.id]) }
                Divider()
                Button("永久删除…", role: .destructive) {
                  selection = [recycled.id]
                  isPermanentDeleteConfirmationPresented = true
                }
              }
          }
        }
        .accessibilityLabel("资料回收站列表")
        .accessibilityValue("共 \(knowledge.recycledDocuments.count) 条，已选择 \(selection.count) 条")
      }

      Divider()
      HStack {
        Label("回收站资料不会参与全文搜索或语义检索", systemImage: "info.circle")
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
      }
      .padding(12)

      Divider()

      HStack {
        Button("取消") { dismiss() }
          .keyboardShortcut(.cancelAction)
        Spacer()
        Text("已选择 \(selection.count) 条")
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
        Button("永久删除…", role: .destructive) {
          isPermanentDeleteConfirmationPresented = true
        }
        .disabled(selection.isEmpty || knowledge.isBusy)
        Button("恢复所选") { restoreSelection() }
          .workbenchProminentActionStyle()
          .keyboardShortcut(.defaultAction)
          .disabled(selection.isEmpty || knowledge.isBusy)
      }
      .padding(14)
    }
    .frame(minWidth: 680, idealWidth: 780, minHeight: 480, idealHeight: 620)
    .confirmationDialog(
      "永久删除所选资料？",
      isPresented: $isPermanentDeleteConfirmationPresented,
      titleVisibility: .visible
    ) {
      Button("永久删除 \(selection.count) 条资料", role: .destructive) {
        permanentlyDeleteSelection()
      }
      Button("取消", role: .cancel) {}
    } message: {
      Text("这会清理资料库正文、网页归档、所有版本、标注、反向链接和检索索引。磁盘上的外部原始文件不会被删除，此操作无法撤销。")
    }
  }

  private func recycledRow(_ recycled: KnowledgeRecycledDocument) -> some View {
    HStack(spacing: 10) {
      Image(systemName: recycled.document.kind.systemImage)
        .foregroundStyle(.secondary)
        .frame(width: 20)
      VStack(alignment: .leading, spacing: 3) {
        Text(recycled.document.title)
          .workbenchTruncatedIdentity(recycled.document.title)
        Text(
          "移除于 \(recycled.deletedAt.formatted(date: .abbreviated, time: .shortened))"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      Spacer()
      Text(ByteCountFormatter.string(
        fromByteCount: recycled.document.sourceByteCount,
        countStyle: .file
      ))
      .font(.caption.monospacedDigit())
      .foregroundStyle(.secondary)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(
      "\(recycled.document.title)，移除于 \(recycled.deletedAt.formatted(date: .abbreviated, time: .shortened))"
    )
  }

  private func restoreSelection() {
    restore(selection)
  }

  private func restore(_ documentIDs: Set<UUID>) {
    let count = documentIDs.count
    guard knowledge.restoreFromRecycleBin(documentIDs) else { return }
    selection.subtract(documentIDs)
    EditorAccessibilityAnnouncementCenter.announce(
      "已从回收站恢复 \(count) 条资料。",
      priority: .medium
    )
  }

  private func permanentlyDeleteSelection() {
    let ids = selection
    var deletedCount = 0
    for id in ids where knowledge.deleteDocument(id) {
      deletedCount += 1
      selection.remove(id)
    }
    EditorAccessibilityAnnouncementCenter.announce(
      "已永久删除 \(deletedCount) 条资料。",
      priority: .medium
    )
  }
}
