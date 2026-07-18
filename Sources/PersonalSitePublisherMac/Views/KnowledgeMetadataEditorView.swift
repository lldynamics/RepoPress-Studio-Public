import PublishingWorkbenchCore
import SwiftUI

struct KnowledgeMetadataEditorView: View {
  @Environment(\.dismiss) private var dismiss
  let documentID: UUID
  let onSave: (KnowledgeDocumentMetadata) -> Bool
  @State private var kind: KnowledgeDocumentKind
  @State private var title: String
  @State private var authors: String
  @State private var language: String
  @State private var summary: String
  @State private var tags: String

  init(
    document: KnowledgeDocument,
    onSave: @escaping (KnowledgeDocumentMetadata) -> Bool
  ) {
    documentID = document.id
    self.onSave = onSave
    _kind = State(initialValue: document.kind)
    _title = State(initialValue: document.title)
    _authors = State(initialValue: document.authors.joined(separator: "，"))
    _language = State(initialValue: document.language ?? "")
    _summary = State(initialValue: document.summary)
    _tags = State(initialValue: document.tags.joined(separator: "，"))
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Label("编辑资料元数据", systemImage: "pencil.and.list.clipboard")
          .font(.headline)
        Spacer()
      }
      .padding(14)
      Divider()

      Form {
        Picker("资料类型", selection: $kind) {
          ForEach(KnowledgeDocumentKind.allCases) { kind in
            Label(kind.localizedDisplayName, systemImage: kind.systemImage)
              .tag(kind)
          }
        }
        TextField("标题", text: $title)
          .accessibilityLabel("标题")
        TextField("作者（用逗号分隔）", text: $authors)
          .accessibilityLabel("作者")
        TextField("语言", text: $language)
          .accessibilityLabel("语言")
        TextField("标签（用逗号分隔）", text: $tags)
          .accessibilityLabel("标签")
        VStack(alignment: .leading, spacing: 6) {
          Text("摘要")
          TextEditor(text: $summary)
            .font(.body)
            .accessibilityLabel("摘要")
            .frame(minHeight: 140)
            .overlay {
              RoundedRectangle(cornerRadius: 6)
                .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
            }
        }
      }
      .formStyle(.grouped)
      .padding(12)

      Divider()

      HStack {
        Button("取消") { dismiss() }
          .keyboardShortcut(.cancelAction)
        Spacer()
        Button("保存") { save() }
          .workbenchProminentActionStyle()
          .keyboardShortcut(.defaultAction)
          .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
      .padding(14)
    }
    .frame(minWidth: 560, idealWidth: 640, minHeight: 500, idealHeight: 580)
    .accessibilityIdentifier("knowledge-metadata-editor")
  }

  private func save() {
    let metadata = KnowledgeDocumentMetadata(
      kind: kind,
      title: title,
      authors: separatedValues(authors),
      language: language.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
      summary: summary,
      tags: separatedValues(tags)
    )
    if onSave(metadata) { dismiss() }
  }

  private func separatedValues(_ value: String) -> [String] {
    value
      .components(separatedBy: CharacterSet(charactersIn: ",，;；\n"))
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
  }
}
