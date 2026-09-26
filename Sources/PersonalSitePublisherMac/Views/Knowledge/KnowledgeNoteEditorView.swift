import AppKit
import PublishingKnowledgeCore
import SwiftUI
import UniformTypeIdentifiers

struct KnowledgeNoteEditorView: View {
  private struct FormDraft: Equatable {
    var title: String
    var tags: String
    var sourceURL: String
    var markdown: String
    var isArchived: Bool
    var attachments: [KnowledgeNoteAttachment]

    init(
      title: String,
      tags: String,
      sourceURL: String,
      markdown: String,
      isArchived: Bool,
      attachments: [KnowledgeNoteAttachment]
    ) {
      self.title = title
      self.tags = tags
      self.sourceURL = sourceURL
      self.markdown = markdown
      self.isArchived = isArchived
      self.attachments = attachments
    }

    init(note: KnowledgeNote) {
      self.init(
        title: note.title,
        tags: note.tags.joined(separator: "，"),
        sourceURL: note.sourceURL?.absoluteString ?? "",
        markdown: note.markdown,
        isArchived: note.isArchived,
        attachments: note.attachments
      )
    }
  }

  @Environment(\.dismiss) private var dismiss
  let note: KnowledgeNote
  let onSave: (KnowledgeNote, String?) async -> KnowledgeNoteEditorSaveResult
  let onCreateConflictCopy: (KnowledgeNote) async -> (KnowledgeNote, String)?

  @State private var title: String
  @State private var tags: String
  @State private var sourceURL: String
  @State private var markdown: String
  @State private var isArchived: Bool
  @State private var attachments: [KnowledgeNoteAttachment]
  @State private var attachmentErrorMessage: String?
  @State private var sourceURLErrorMessage: String?
  @State private var saveErrorMessage: String?
  @State private var expectedContentRevision: String?
  @State private var conflictCopy: KnowledgeNote?
  @State private var staleConflictDetected = false
  @State private var baselineDraft: FormDraft
  @State private var isSaving = false
  @State private var isDiscardConfirmationPresented = false

  init(
    note: KnowledgeNote,
    expectedContentRevision: String,
    onSave: @escaping (KnowledgeNote, String?) async -> KnowledgeNoteEditorSaveResult,
    onCreateConflictCopy: @escaping (KnowledgeNote) async -> (KnowledgeNote, String)?
  ) {
    self.note = note
    self.onSave = onSave
    self.onCreateConflictCopy = onCreateConflictCopy
    _expectedContentRevision = State(initialValue: expectedContentRevision)
    _title = State(initialValue: note.title)
    _tags = State(initialValue: note.tags.joined(separator: "，"))
    _sourceURL = State(initialValue: note.sourceURL?.absoluteString ?? "")
    _markdown = State(initialValue: note.markdown)
    _isArchived = State(initialValue: note.isArchived)
    _attachments = State(initialValue: note.attachments)
    _baselineDraft = State(initialValue: FormDraft(note: note))
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Label("本地笔记", systemImage: "note.text")
          .font(.headline)
        Spacer()
        Text("先保存到本机；开启 iCloud 同步后会上传笔记与附件。")
          .font(.workbenchSupporting)
          .foregroundStyle(.secondary)
      }
      .padding(14)
      Divider()

      Form {
        TextField("标题（可选）", text: $title)
          .accessibilityLabel("笔记标题")
        TextField("标签，用逗号分隔", text: $tags)
          .accessibilityLabel("笔记标签")
        TextField("来源地址（可选）", text: $sourceURL)
          .accessibilityLabel("笔记来源地址")
          .onChange(of: sourceURL) { _, _ in sourceURLErrorMessage = nil }
        if let sourceURLErrorMessage {
          Label(sourceURLErrorMessage, systemImage: "exclamationmark.triangle.fill")
            .font(.workbenchSupporting)
            .foregroundStyle(.red)
            .accessibilityIdentifier("knowledge-note-source-url-error")
        }
        Toggle("归档", isOn: $isArchived)
          .accessibilityLabel("归档笔记")
        VStack(alignment: .leading, spacing: 6) {
          Text("Markdown 正文")
          TextEditor(text: $markdown)
            .font(.body.monospaced())
            .accessibilityLabel("笔记 Markdown 正文")
            .frame(minHeight: 300)
            .overlay {
              RoundedRectangle(cornerRadius: 6)
                .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
            }
        }
        Section("附件") {
          if attachments.isEmpty {
            Text("还没有附件")
              .foregroundStyle(.secondary)
          } else {
            ForEach(attachments) { attachment in
              HStack {
                Label(attachment.fileName, systemImage: "paperclip")
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.data.count), countStyle: .file))
                  .foregroundStyle(.secondary)
                Button("移除", role: .destructive) {
                  attachments.removeAll { $0.id == attachment.id }
                }
              }
            }
          }
          Button {
            addAttachments()
          } label: {
            Label("添加本地附件…", systemImage: "paperclip.badge.plus")
          }
          Text("保存时会将所选文件复制进本机资料库。")
            .font(.workbenchSupporting)
            .foregroundStyle(.secondary)
        }
      }
      .formStyle(.grouped)
      .padding(12)
      .disabled(isSaving)

      Divider()
      if isUnprotectedConflict {
        Label("原笔记已更新；你的输入尚未写入副本。请重试保存副本后再关闭。", systemImage: "exclamationmark.triangle.fill")
          .foregroundStyle(.orange)
          .padding(.horizontal, 14)
        Button("重试保存为冲突副本") { persistConflictCopy() }
          .padding(.horizontal, 14)
      }
      HStack {
        Button("取消") { requestClose() }
          .disabled(isSaving || isUnprotectedConflict)
          .keyboardShortcut(.cancelAction)
        Spacer()
        Button {
          save()
        } label: {
          if isSaving {
            Label("正在保存", systemImage: "arrow.triangle.2.circlepath")
          } else {
            Text("保存")
          }
        }
          .workbenchProminentActionStyle()
          .disabled(isSaving)
          .keyboardShortcut(.defaultAction)
      }
      .padding(14)
    }
    .frame(minWidth: 680, idealWidth: 820, minHeight: 560, idealHeight: 720)
    .accessibilityIdentifier("knowledge-note-editor")
    .alert("无法添加附件", isPresented: Binding(
      get: { attachmentErrorMessage != nil },
      set: { if !$0 { attachmentErrorMessage = nil } }
    )) {
      Button("好", role: .cancel) {}
    } message: {
      Text(attachmentErrorMessage ?? "")
    }
    .interactiveDismissDisabled(hasUnsavedChanges || isSaving || isUnprotectedConflict)
    .confirmationDialog(
      "放弃未保存的更改？",
      isPresented: $isDiscardConfirmationPresented,
      titleVisibility: .visible
    ) {
      Button("保存") { save() }
      Button("放弃更改", role: .destructive) { dismiss() }
      Button("继续编辑", role: .cancel) {}
    } message: {
      Text("关闭后，本次尚未保存的笔记更改将丢失。")
    }
    .alert(isStaleConflict ? "笔记已在其他设备更新" : "保存笔记失败", isPresented: Binding(
      get: { saveErrorMessage != nil },
      set: { if !$0 { saveErrorMessage = nil } }
    )) {
      if isStaleConflict, conflictCopy != nil {
        Button("保存副本并关闭") { dismiss() }
        Button("继续编辑副本") { saveErrorMessage = nil }
      } else if isStaleConflict {
        Button("重试保存为冲突副本") { persistConflictCopy() }
        Button("继续编辑") { saveErrorMessage = nil }
      } else {
        Button("好", role: .cancel) {}
      }
    } message: {
      Text(saveErrorMessage ?? "")
    }
  }

  @MainActor
  private func save() {
    guard !isSaving else { return }
    let parsedSourceURL: URL?
    do {
      parsedSourceURL = try KnowledgeLibraryService.noteSourceURL(from: sourceURL)
      sourceURLErrorMessage = nil
    } catch {
      sourceURLErrorMessage = error.localizedDescription
      return
    }
    let target = conflictCopy ?? note
    let updated = KnowledgeNote(
      id: target.id,
      title: title,
      tags: separatedValues(tags),
      createdAt: target.createdAt,
      updatedAt: Date(),
      isArchived: isArchived,
      sourceURL: parsedSourceURL,
      markdown: markdown,
      attachments: attachments
    )
    isSaving = true
    Task { @MainActor in
      defer { isSaving = false }
      switch await onSave(updated, expectedContentRevision) {
      case .saved:
        dismiss()
      case .staleRevision:
        staleConflictDetected = true
        await createDurableConflictCopy(from: updated)
      case .failure(let message):
        saveErrorMessage = message
      }
    }
  }

  private var isStaleConflict: Bool {
    staleConflictDetected
  }

  private var isUnprotectedConflict: Bool {
    isStaleConflict && conflictCopy == nil
  }

  private var currentDraft: FormDraft {
    FormDraft(
      title: title,
      tags: tags,
      sourceURL: sourceURL,
      markdown: markdown,
      isArchived: isArchived,
      attachments: attachments
    )
  }

  private var hasUnsavedChanges: Bool {
    currentDraft != baselineDraft
  }

  @MainActor
  private func requestClose() {
    guard !isSaving, !isUnprotectedConflict else { return }
    if hasUnsavedChanges {
      isDiscardConfirmationPresented = true
    } else {
      dismiss()
    }
  }

  @MainActor
  private func persistConflictCopy() {
    guard isStaleConflict, conflictCopy == nil, !isSaving else { return }
    let parsedSourceURL: URL?
    do {
      parsedSourceURL = try KnowledgeLibraryService.noteSourceURL(from: sourceURL)
      sourceURLErrorMessage = nil
    } catch {
      sourceURLErrorMessage = error.localizedDescription
      return
    }
    let draft = KnowledgeNote(
      id: note.id,
      title: title,
      tags: separatedValues(tags),
      createdAt: note.createdAt,
      updatedAt: Date(),
      isArchived: isArchived,
      sourceURL: parsedSourceURL,
      markdown: markdown,
      attachments: attachments
    )
    isSaving = true
    Task { @MainActor in
      defer { isSaving = false }
      await createDurableConflictCopy(from: draft)
    }
  }

  @MainActor
  private func createDurableConflictCopy(from draft: KnowledgeNote) async {
    var copy = draft
    copy.id = UUID()
    let conflictCopyLabel = String(localized: "冲突副本")
    copy.title = copy.title.isEmpty ? conflictCopyLabel : "\(copy.title)（\(conflictCopyLabel)）"
    copy.updatedAt = Date()
    copy.attachments = copy.attachments.map { attachment in
      var newAttachment = attachment
      newAttachment.id = UUID()
      return newAttachment
    }
    guard let saved = await onCreateConflictCopy(copy) else {
      saveErrorMessage = String(localized: "原笔记已在其他设备更新。副本暂未保存，请重试；关闭窗口会丢失当前输入。")
      return
    }
    conflictCopy = saved.0
    expectedContentRevision = saved.1
    title = saved.0.title
    tags = saved.0.tags.joined(separator: "，")
    sourceURL = saved.0.sourceURL?.absoluteString ?? ""
    markdown = saved.0.markdown
    isArchived = saved.0.isArchived
    attachments = saved.0.attachments
    baselineDraft = FormDraft(note: saved.0)
    saveErrorMessage = String(localized: "原笔记已在其他设备更新；你的输入已保存为本机冲突副本。可以继续编辑副本，或关闭窗口。")
  }

  private func separatedValues(_ value: String) -> [String] {
    value
      .components(separatedBy: CharacterSet(charactersIn: ",，;；\n"))
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
  }

  @MainActor
  private func addAttachments() {
    let panel = NSOpenPanel()
    panel.title = String(localized: "添加本地附件")
    panel.prompt = String(localized: "添加")
    panel.message = String(localized: "选中的文件会复制进这条本地笔记。")
    panel.allowsMultipleSelection = true
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    Task { @MainActor in
      guard await WindowSheetPresenter.response(to: panel) == .OK else { return }
      do {
        let newAttachments = try panel.urls.map(readAttachment(at:))
        attachments.append(contentsOf: newAttachments)
      } catch {
        attachmentErrorMessage = error.localizedDescription
      }
    }
  }

  private func readAttachment(at url: URL) throws -> KnowledgeNoteAttachment {
    let accessedSecurityScopedResource = url.startAccessingSecurityScopedResource()
    defer {
      if accessedSecurityScopedResource { url.stopAccessingSecurityScopedResource() }
    }
    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    guard values.isRegularFile == true else {
      throw KnowledgeLibraryError.invalidMetadata("附件必须是一个普通文件。")
    }
    guard (values.fileSize ?? 0) <= 128 * 1_024 * 1_024 else {
      throw KnowledgeLibraryError.sourceLimitExceeded("笔记附件超过 128 MB。")
    }
    let data = try Data(contentsOf: url, options: .mappedIfSafe)
    let mimeType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
      ?? "application/octet-stream"
    return KnowledgeNoteAttachment(
      fileName: url.lastPathComponent,
      mimeType: mimeType,
      data: data
    )
  }
}
