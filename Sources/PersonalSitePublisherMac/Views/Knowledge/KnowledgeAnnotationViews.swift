import PublishingWorkbenchCore
import SwiftUI

struct KnowledgeAnnotationEditorView: View {
  @Environment(\.dismiss) private var dismiss
  let original: KnowledgeAnnotation
  let onSave: (KnowledgeAnnotation) async -> Bool
  @State private var highlightedText: String
  @State private var note: String

  init(
    annotation: KnowledgeAnnotation,
    onSave: @escaping (KnowledgeAnnotation) async -> Bool
  ) {
    original = annotation
    self.onSave = onSave
    _highlightedText = State(initialValue: annotation.highlightedText)
    _note = State(initialValue: annotation.note)
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Label(original.note.isEmpty ? "新增资料标注" : "编辑资料标注", systemImage: "highlighter")
          .font(.headline)
        Spacer()
      }
      .padding(14)
      Divider()

      VStack(alignment: .leading, spacing: 14) {
        if let locator = original.locator?.nilIfEmpty {
          Label(locator, systemImage: "scope")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        VStack(alignment: .leading, spacing: 6) {
          Text("引用文字（可选）")
            .font(.callout.weight(.medium))
          TextEditor(text: $highlightedText)
            .accessibilityLabel("引用文字（可选）")
            .frame(minHeight: 110)
            .font(.body)
            .overlay(editorBorder)
        }
        VStack(alignment: .leading, spacing: 6) {
          Text("笔记")
            .font(.callout.weight(.medium))
          TextEditor(text: $note)
            .accessibilityLabel("笔记")
            .frame(minHeight: 180)
            .font(.body)
            .overlay(editorBorder)
        }
      }
      .padding(18)

      Divider()

      HStack {
        Button("取消") { dismiss() }
          .keyboardShortcut(.cancelAction)
        Spacer()
        Button("保存") { save() }
          .workbenchProminentActionStyle()
          .keyboardShortcut(.defaultAction)
          .disabled(note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
      .padding(14)
    }
    .frame(minWidth: 560, idealWidth: 640, minHeight: 460, idealHeight: 540)
    .accessibilityIdentifier("knowledge-annotation-editor")
  }

  private var editorBorder: some View {
    RoundedRectangle(cornerRadius: 6)
      .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
  }

  private func save() {
    var updated = original
    updated.highlightedText = highlightedText
    updated.note = note
    Task {
      if await onSave(updated) { dismiss() }
    }
  }
}

struct KnowledgeDocumentInsightsSection: View {
  let annotations: [KnowledgeAnnotation]
  let backlinkGroups: [KnowledgeBacklinkGroup]
  let onAddAnnotation: () -> Void
  let onEditAnnotation: (KnowledgeAnnotation) -> Void
  let onDeleteAnnotation: (UUID) -> Void
  var showsHeader = true
  @State private var expandedBacklinkGroupIDs = Set<String>()

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      if showsHeader {
        HStack {
          Label("标注与反向链接", systemImage: "link.badge.plus")
            .font(.headline)
          Spacer()
          Button("添加笔记", action: onAddAnnotation)
            .controlSize(.small)
        }
      }

      if annotations.isEmpty && backlinkGroups.isEmpty {
        Text("还没有标注或引用记录。添加笔记，或让 AI 把资料引用写入文章后，这里会显示关联。")
          .font(.callout)
          .foregroundStyle(.secondary)
      }

      ForEach(annotations) { annotation in
        annotationRow(annotation)
      }

      if !annotations.isEmpty && !backlinkGroups.isEmpty { Divider() }

      ForEach(backlinkGroups) { group in
        backlinkGroupRow(group)
      }
    }
    .padding(14)
    .background(Color.secondary.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
    .accessibilityElement(children: .contain)
  }

  private func annotationRow(_ annotation: KnowledgeAnnotation) -> some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: "highlighter")
        .foregroundStyle(.tint)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 4) {
        if let locator = annotation.locator?.nilIfEmpty {
          Text(locator)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
        }
        if !annotation.highlightedText.isEmpty {
          Text(annotation.highlightedText)
            .font(.callout)
            .lineLimit(3)
            .foregroundStyle(.secondary)
        }
        Text(annotation.note)
          .font(.body)
          .lineLimit(5)
      }
      .accessibilityElement(children: .combine)
      .accessibilityLabel("标注：\(annotation.note)")
      Spacer(minLength: 8)
      Menu {
        Button("编辑") { onEditAnnotation(annotation) }
        Button("删除标注", role: .destructive) { onDeleteAnnotation(annotation.id) }
      } label: {
        Image(systemName: "ellipsis.circle")
      }
      .menuStyle(.borderlessButton)
      .accessibilityLabel("标注操作")
    }
    .accessibilityElement(children: .contain)
  }

  private func backlinkGroupRow(_ group: KnowledgeBacklinkGroup) -> some View {
    DisclosureGroup(
      isExpanded: Binding(
        get: { expandedBacklinkGroupIDs.contains(group.id) },
        set: { isExpanded in
          if isExpanded {
            expandedBacklinkGroupIDs.insert(group.id)
          } else {
            expandedBacklinkGroupIDs.remove(group.id)
          }
        }
      )
    ) {
      VStack(alignment: .leading, spacing: 8) {
        ForEach(group.backlinks) { backlink in
          HStack(alignment: .top, spacing: 8) {
            Image(systemName: "text.quote")
              .font(.caption)
              .foregroundStyle(.tertiary)
              .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
              Text(backlink.chunkLocator?.nilIfEmpty ?? "正文片段")
                .font(.caption.weight(.semibold))
              if let excerpt = backlink.chunkExcerpt?.nilIfEmpty {
                Text(excerpt)
                  .font(.caption)
                  .foregroundStyle(.secondary)
                  .lineLimit(3)
              }
            }
          }
          .accessibilityElement(children: .combine)
          .accessibilityLabel(
            "引用片段：\(backlink.chunkLocator?.nilIfEmpty ?? "正文片段")。"
              + (backlink.chunkExcerpt?.nilIfEmpty ?? "")
          )
        }
      }
      .padding(.top, 7)
      .padding(.leading, 26)
    } label: {
      HStack(alignment: .top, spacing: 10) {
        Image(systemName: group.targetKind == .articleDraft ? "doc.text" : "bubble.left.and.text.bubble.right")
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 3) {
          Text(group.targetTitle)
            .font(.callout.weight(.medium))
          HStack(spacing: 6) {
            Text(targetKindTitle(group.targetKind))
            if let location = group.targetLocation?.nilIfEmpty { Text("· \(location)") }
            Text("· 引用 \(group.citedChunkIDs.count) 个片段")
            Text("· \(group.createdAt.formatted(date: .abbreviated, time: .shortened))")
          }
          .font(.caption)
          .foregroundStyle(.secondary)
        }
        Spacer()
      }
    }
    .accessibilityLabel(
      "被\(targetKindTitle(group.targetKind))“\(group.targetTitle)”引用，"
        + "共 \(group.citedChunkIDs.count) 个片段"
    )
  }

  private func targetKindTitle(_ kind: KnowledgeBacklinkTargetKind) -> String {
    switch kind {
    case .articleDraft: String(localized: "文章")
    case .aiResponse: String(localized: "AI 回复")
    }
  }
}
