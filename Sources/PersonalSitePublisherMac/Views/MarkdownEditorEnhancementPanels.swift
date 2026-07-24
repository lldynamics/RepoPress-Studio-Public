import PublishingWorkbenchCore
import SwiftUI

struct MarkdownInternalLinkPicker: View {
  @Environment(\.dismiss) private var dismiss
  let draft: ArticleDraft
  let drafts: [ArticleDraft]
  let profile: SiteProfile
  let selectedText: String
  let onInsert: (MarkdownInternalLinkSuggestion) -> Void
  let onOpenBacklink: (ArticleDraft.ID) -> Void
  let onInsertExternalLink: () -> Void
  @State private var query = ""
  @FocusState private var isQueryFocused: Bool

  var body: some View {
    VStack(spacing: 0) {
      panelHeader(title: "插入站内链接", systemImage: "link.badge.plus")
      Divider()
      HStack {
        Image(systemName: "magnifyingglass")
          .foregroundStyle(.secondary)
        TextField("搜索标题、Slug、标签或摘要", text: $query)
          .textFieldStyle(.plain)
          .focused($isQueryFocused)
          .accessibilityLabel("搜索标题、Slug、标签或摘要")
      }
      .padding(12)
      Divider()

      HSplitView {
        VStack(alignment: .leading, spacing: 8) {
          Text("可链接文章")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
          if suggestions.isEmpty {
            ContentUnavailableView("没有匹配文章", systemImage: "link.badge.plus")
              .frame(maxWidth: .infinity, maxHeight: .infinity)
          } else {
            List(suggestions) { suggestion in
              Button {
                onInsert(suggestion)
                dismiss()
              } label: {
                VStack(alignment: .leading, spacing: 3) {
                  Text(suggestion.title)
                    .foregroundStyle(.primary)
                  Text(suggestion.destination)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                  if !suggestion.summary.isEmpty {
                    Text(suggestion.summary)
                      .font(.caption)
                      .foregroundStyle(.tertiary)
                      .lineLimit(2)
                  }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
              }
              .buttonStyle(.plain)
            }
            .listStyle(.inset)
          }
        }
        .padding(12)
        .frame(minWidth: 360)

        VStack(alignment: .leading, spacing: 10) {
          Text("反向链接")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
          if backlinks.isEmpty {
            Text("还没有其他文章链接到当前文章。")
              .font(.callout)
              .foregroundStyle(.secondary)
          } else {
            ForEach(backlinks) { backlink in
              Button {
                onOpenBacklink(backlink.sourceDraftID)
                dismiss()
              } label: {
                Label(backlink.sourceTitle, systemImage: "arrow.turn.down.left")
                  .frame(maxWidth: .infinity, alignment: .leading)
              }
              .buttonStyle(.plain)
            }
          }
          Spacer()
          Button {
            onInsertExternalLink()
            dismiss()
          } label: {
            Label("插入外部链接模板", systemImage: "globe")
          }
        }
        .padding(14)
        .frame(minWidth: 220, maxWidth: 280, maxHeight: .infinity, alignment: .topLeading)
      }
    }
    .frame(width: 720, height: 520)
    .onAppear { isQueryFocused = true }
    .accessibilityLabel("站内链接选择器")
  }

  private var suggestions: [MarkdownInternalLinkSuggestion] {
    MarkdownInternalLinkService.suggestions(
      for: draft,
      among: drafts,
      profile: profile,
      query: query
    )
  }

  private var backlinks: [MarkdownBacklink] {
    MarkdownInternalLinkService.backlinks(to: draft, among: drafts, profile: profile)
  }

  private func panelHeader(title: String, systemImage: String) -> some View {
    HStack {
      Label(title, systemImage: systemImage)
        .font(.headline)
      Spacer()
      Button("完成") { dismiss() }
    }
    .padding(14)
  }
}

struct MarkdownDiagnosticsPanel: View {
  @Environment(\.dismiss) private var dismiss
  let diagnostics: [MarkdownInlineDiagnostic]
  let onSelect: (MarkdownInlineDiagnostic) -> Void
  let onQuickFix: (MarkdownInlineDiagnostic) -> Void

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Label("正文诊断", systemImage: diagnostics.isEmpty ? "checkmark.circle.fill" : "waveform.badge.exclamationmark")
          .font(.headline)
          .foregroundStyle(diagnostics.isEmpty ? WorkbenchTheme.success : .primary)
        Spacer()
        Text(diagnostics.isEmpty ? "没有发现问题" : "\(diagnostics.count) 项")
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
        Button("完成") { dismiss() }
      }
      .padding(14)
      Divider()

      if diagnostics.isEmpty {
        ContentUnavailableView(
          "正文检查通过",
          systemImage: "checkmark.seal.fill",
          description: Text("标题层级、图片 alt 和脚注引用没有发现问题。")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        List(diagnostics) { diagnostic in
          VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
              Label(
                diagnostic.title,
                systemImage: diagnostic.severity == .error ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill"
              )
              .foregroundStyle(diagnostic.severity == .error ? WorkbenchTheme.risk : WorkbenchTheme.warning)
              Spacer()
              Text("位置 \(diagnostic.range.location)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
            }
            Text(diagnostic.message)
              .font(.callout)
              .foregroundStyle(.secondary)
            HStack {
              Button("定位") {
                onSelect(diagnostic)
                dismiss()
              }
              if diagnostic.quickFixTitle != nil {
                Button("快速修复") {
                  onQuickFix(diagnostic)
                }
                .workbenchProminentActionStyle()
              }
            }
            .controlSize(.small)
          }
          .padding(.vertical, 5)
        }
      }
    }
    .frame(width: 620, height: 480)
    .accessibilityLabel("Markdown 正文诊断")
  }
}

struct MarkdownSnippetLibraryPanel: View {
  @Environment(\.dismiss) private var dismiss
  let draft: ArticleDraft
  let siteName: String
  let storedCustomSnippets: [MarkdownSnippet]
  let onInsert: (MarkdownSnippet) -> Void
  let onSaveCustomSnippet: (MarkdownSnippet) -> Void
  let onDeleteCustomSnippet: (MarkdownSnippet) -> Void
  @State private var query = ""
  @State private var selectedKind: MarkdownSnippetKind?
  @State private var customSnippets: [MarkdownSnippet] = []
  @State private var snippetBeingEdited: MarkdownSnippet?
  @State private var snippetPendingDeletion: MarkdownSnippet?
  @State private var isCustomSnippetEditorPresented = false
  @FocusState private var isQueryFocused: Bool

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Label("文章模板与正文片段", systemImage: "doc.on.clipboard")
          .font(.headline)
        Spacer()
        Button {
          snippetBeingEdited = nil
          isCustomSnippetEditorPresented = true
        } label: {
          Label("新建站点片段", systemImage: "plus")
        }
        .help("为“\(siteName)”创建可复用的片段")
        .accessibilityLabel("新建当前站点片段")
        Button("完成") { dismiss() }
      }
      .padding(14)
      Divider()
      HStack(spacing: 10) {
        TextField("搜索模板或片段", text: $query)
          .textFieldStyle(.roundedBorder)
          .focused($isQueryFocused)
          .accessibilityLabel("搜索模板或片段")
        Picker("类型", selection: $selectedKind) {
          Text("全部").tag(MarkdownSnippetKind?.none)
          Text("文章模板").tag(MarkdownSnippetKind?.some(.articleTemplate))
          Text("正文片段").tag(MarkdownSnippetKind?.some(.snippet))
        }
        .frame(width: 140)
      }
      .padding(12)
      Divider()

      List(filteredSnippets) { snippet in
        HStack(spacing: 12) {
          Image(systemName: snippet.systemImage)
            .font(.title3)
            .frame(width: 28)
            .foregroundStyle(WorkbenchTheme.primary)
          VStack(alignment: .leading, spacing: 3) {
            Text(snippet.title)
              .font(.callout.weight(.medium))
            Text(snippet.detail.isEmpty ? "站点自定义片段" : snippet.detail)
              .font(.workbenchSupporting)
              .foregroundStyle(.secondary)
            if snippet.isSiteScoped {
              Label(siteName, systemImage: "building.2")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Text(MarkdownSnippetLibraryService.expandedMarkdown(for: snippet, draft: draft))
              .font(.caption.monospaced())
              .foregroundStyle(.tertiary)
              .lineLimit(2)
          }
          Spacer()
          Button("插入") {
            onInsert(snippet)
            dismiss()
          }
          .workbenchProminentActionStyle()
          if snippet.isSiteScoped {
            Menu {
              Button("编辑") {
                snippetBeingEdited = snippet
                isCustomSnippetEditorPresented = true
              }
              Button("删除", role: .destructive) {
                snippetPendingDeletion = snippet
              }
            } label: {
              Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("管理站点片段")
            .accessibilityLabel("管理片段：\(snippet.title)")
          }
        }
        .padding(.vertical, 5)
      }
    }
    .frame(width: 680, height: 520)
    .onAppear {
      customSnippets = storedCustomSnippets
      isQueryFocused = true
    }
    .sheet(isPresented: $isCustomSnippetEditorPresented) {
      MarkdownCustomSnippetEditorPanel(
        siteProfileID: draft.siteProfileID,
        siteName: siteName,
        snippet: snippetBeingEdited,
        onSave: saveCustomSnippet
      )
    }
    .confirmationDialog(
      "删除站点片段？",
      isPresented: deleteConfirmationPresented,
      titleVisibility: .visible
    ) {
      if let snippetPendingDeletion {
        Button("删除“\(snippetPendingDeletion.title)”", role: .destructive) {
          deleteCustomSnippet(snippetPendingDeletion)
        }
      }
      Button("取消", role: .cancel) {}
    } message: {
      Text("删除后不会影响已经插入文章的内容。")
    }
    .accessibilityLabel("文章模板与正文片段")
  }

  private var filteredSnippets: [MarkdownSnippet] {
    MarkdownSnippetLibraryService.availableSnippets(
      for: draft.siteProfileID,
      customSnippets: customSnippets
    ).filter { snippet in
      (selectedKind == nil || snippet.kind == selectedKind)
        && (query.trimmedForPublishing.isEmpty
          || snippet.title.localizedStandardContains(query)
          || snippet.detail.localizedStandardContains(query)
          || snippet.markdown.localizedStandardContains(query))
    }
  }

  private var deleteConfirmationPresented: Binding<Bool> {
    Binding(
      get: { snippetPendingDeletion != nil },
      set: { isPresented in
        if !isPresented {
          snippetPendingDeletion = nil
        }
      }
    )
  }

  private func saveCustomSnippet(_ snippet: MarkdownSnippet) {
    customSnippets = MarkdownSnippetLibraryService.savingCustomSnippet(
      id: snippet.id,
      title: snippet.title,
      detail: snippet.detail,
      kind: snippet.kind,
      markdown: snippet.markdown,
      siteProfileID: draft.siteProfileID,
      in: customSnippets
    )
    if let saved = customSnippets.first(where: { $0.id == snippet.id }) {
      onSaveCustomSnippet(saved)
    }
  }

  private func deleteCustomSnippet(_ snippet: MarkdownSnippet) {
    customSnippets = MarkdownSnippetLibraryService.removingCustomSnippet(
      id: snippet.id,
      from: customSnippets
    )
    snippetPendingDeletion = nil
    onDeleteCustomSnippet(snippet)
  }
}

private struct MarkdownCustomSnippetEditorPanel: View {
  @Environment(\.dismiss) private var dismiss
  let siteProfileID: UUID
  let siteName: String
  let snippet: MarkdownSnippet?
  let onSave: (MarkdownSnippet) -> Void
  @State private var title: String
  @State private var detail: String
  @State private var kind: MarkdownSnippetKind
  @State private var markdown: String
  @FocusState private var isTitleFocused: Bool

  init(
    siteProfileID: UUID,
    siteName: String,
    snippet: MarkdownSnippet?,
    onSave: @escaping (MarkdownSnippet) -> Void
  ) {
    self.siteProfileID = siteProfileID
    self.siteName = siteName
    self.snippet = snippet
    self.onSave = onSave
    _title = State(initialValue: snippet?.title ?? "")
    _detail = State(initialValue: snippet?.detail ?? "")
    _kind = State(initialValue: snippet?.kind ?? .snippet)
    _markdown = State(initialValue: snippet?.markdown ?? "")
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Label(snippet == nil ? "新建站点片段" : "编辑站点片段", systemImage: "text.badge.plus")
          .font(.headline)
        Spacer()
      }
      .padding(14)
      Divider()

      Form {
        Section("所属站点") {
          Label(siteName, systemImage: "building.2")
        }
        Section("片段信息") {
          TextField("名称", text: $title)
            .focused($isTitleFocused)
            .accessibilityLabel("站点片段名称")
          TextField("说明（可选）", text: $detail)
          Picker("类型", selection: $kind) {
            Text("文章模板").tag(MarkdownSnippetKind.articleTemplate)
            Text("正文片段").tag(MarkdownSnippetKind.snippet)
          }
        }
        Section("Markdown 内容") {
          TextEditor(text: $markdown)
            .font(.body.monospaced())
            .frame(minHeight: 210)
            .accessibilityLabel("站点片段 Markdown 内容")
          Text("可使用 {{title}}、{{slug}} 和 {{date}} 占位符。")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      .formStyle(.grouped)

      Divider()

      HStack {
        Button("取消") { dismiss() }
          .keyboardShortcut(.cancelAction)
        Spacer()
        Button("保存") { save() }
          .workbenchProminentActionStyle()
          .keyboardShortcut(.defaultAction)
          .disabled(!canSave)
      }
      .padding(14)
    }
    .frame(width: 560, height: 520)
    .onAppear { isTitleFocused = true }
    .accessibilityLabel(snippet == nil ? "新建站点片段" : "编辑站点片段")
  }

  private var canSave: Bool {
    !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private func save() {
    guard let saved = MarkdownSnippetLibraryService.savingCustomSnippet(
      id: snippet?.id,
      title: title,
      detail: detail,
      kind: kind,
      markdown: markdown,
      siteProfileID: siteProfileID,
      in: []
    ).first else {
      return
    }
    onSave(saved)
    dismiss()
  }
}
