import PublishingKnowledgeCore
import SwiftUI

/// A dedicated archive view for notes. It is intentionally separate from the
/// document recycle bin, whose empty action permanently deletes content.
struct KnowledgeArchivedNotesSheet: View {
  @ObservedObject var knowledge: KnowledgeStore
  @Environment(\.dismiss) private var dismiss
  @State private var notes: [KnowledgeNote] = []
  @State private var errorMessage: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        VStack(alignment: .leading, spacing: 4) {
          Text("归档笔记")
            .font(.title2.weight(.semibold))
          Text("归档笔记不会进入资料回收站，可在这里恢复，也会包含在笔记导出中。")
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button("完成") { dismiss() }
      }

      if notes.isEmpty {
        ContentUnavailableView(
          "没有归档笔记",
          systemImage: "archivebox",
          description: Text("在笔记编辑器中选择“归档”后会显示在这里。")
        )
      } else {
        List(notes) { note in
          VStack(alignment: .leading, spacing: 6) {
            Text(note.title.isEmpty ? "未命名笔记" : note.title)
              .font(.headline)
            if !note.tags.isEmpty {
              Text(note.tags.joined(separator: " · "))
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            if !note.markdown.isEmpty {
              Text(note.markdown)
                .lineLimit(2)
                .foregroundStyle(.secondary)
            }
            HStack {
              Spacer()
              Button("恢复") { restore(note) }
            }
          }
          .padding(.vertical, 4)
        }
      }
    }
    .padding(24)
    .frame(minWidth: 580, minHeight: 360)
    .task { await reload() }
    .alert("归档笔记操作失败", isPresented: Binding(
      get: { errorMessage != nil },
      set: { if !$0 { errorMessage = nil } }
    )) {
      Button("好", role: .cancel) {}
    } message: {
      Text(errorMessage ?? "")
    }
  }

  private func reload() async {
    notes = await knowledge.archivedNotes()
    errorMessage = knowledge.lastError
  }

  private func restore(_ note: KnowledgeNote) {
    var restored = note
    restored.isArchived = false
    Task {
      guard await knowledge.updateNote(restored) != nil else {
        errorMessage = knowledge.lastError ?? "无法恢复归档笔记。"
        return
      }
      await reload()
    }
  }
}
