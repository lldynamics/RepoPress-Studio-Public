import Foundation
import PublishingWorkbenchCore
import SwiftUI

struct KnowledgeLibraryDetailView: View {
  @ObservedObject var knowledge: KnowledgeStore
  @State private var isImportPresented = false
  @State private var documentPendingDeletion: KnowledgeDocument?
  @State private var isDeleteConfirmationPresented = false
  @State private var isMetadataEditorPresented = false
  @State private var annotationDraft: KnowledgeAnnotation?
  @State private var isSourceHistoryPresented = false

  var body: some View {
    Group {
      if let document = knowledge.selectedDocument {
        documentDetail(document)
      } else {
        EmptyStateView(
          title: "资料库",
          message: "导入你读过的 EPUB 书籍、文章、网页或 PDF，写作和对话时 AI 可以按需引用。",
          systemImage: "books.vertical",
          density: .fullPage,
          actionTitle: "导入资料",
          actionSystemImage: "tray.and.arrow.down",
          action: { isImportPresented = true }
        )
      }
    }
    .sheet(isPresented: $isImportPresented) {
      KnowledgeImportAssistantView(knowledge: knowledge)
    }
    .sheet(isPresented: $isMetadataEditorPresented) {
      if let document = knowledge.selectedDocument {
        KnowledgeMetadataEditorView(document: document) { metadata in
          knowledge.updateMetadata(documentID: document.id, metadata: metadata)
        }
      }
    }
    .sheet(item: $annotationDraft) { annotation in
      KnowledgeAnnotationEditorView(annotation: annotation) { updated in
        knowledge.saveAnnotation(updated)
      }
    }
    .sheet(isPresented: $isSourceHistoryPresented) {
      if let documentID = knowledge.selectedDocumentID {
        KnowledgeSourceHistoryView(knowledge: knowledge, documentID: documentID)
      }
    }
    .confirmationDialog(
      deletionConfirmationTitle,
      isPresented: $isDeleteConfirmationPresented,
      titleVisibility: .visible
    ) {
      Button("移到回收站", role: .destructive) {
        confirmDocumentDeletion()
      }
      Button("取消", role: .cancel) {
        documentPendingDeletion = nil
      }
    } message: {
      Text("资料会移到回收站并停止参与搜索与 AI 检索；之后可以恢复。")
    }
  }

  private func documentDetail(_ document: KnowledgeDocument) -> some View {
    VStack(spacing: 0) {
      header(document)
      Divider()

      ScrollViewReader { proxy in
        ScrollView {
          VStack(alignment: .leading, spacing: 18) {
            metadata(document)
            Divider()
            if let activeSearchHit {
              searchLocationBanner(activeSearchHit)
            }
            KnowledgeDocumentReader(
              blocks: readerBlocks,
              isLoading: knowledge.isLoadingSelectedDocumentText,
              errorMessage: knowledge.selectedDocumentTextError,
              highlightedBlockID: readerScrollTarget?.blockID,
              highlightTerms: activeSearchHit?.highlightTerms ?? [],
              retry: { knowledge.selectDocument(document.id) }
            )
            if knowledge.selectedDocumentText.count > 100_000,
               activeSearchResult == nil {
              Text("正文较长，当前详情只显示前 100,000 个字符；全文已完整保存并可检索。")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Divider()
            KnowledgeDocumentInsightsSection(
              annotations: knowledge.annotations,
              backlinkGroups: knowledge.backlinkGroups,
              onAddAnnotation: { beginAddingAnnotation(to: document) },
              onEditAnnotation: { annotationDraft = $0 },
              onDeleteAnnotation: { knowledge.deleteAnnotation($0) }
            )
            Divider()
            KnowledgeRelatedChaptersSection(knowledge: knowledge)
          }
          .padding(24)
          .frame(maxWidth: 900, alignment: .leading)
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: readerScrollTarget) {
          guard let target = readerScrollTarget else { return }
          await Task.yield()
          withAnimation(.easeInOut(duration: 0.24)) {
            proxy.scrollTo(target.blockID, anchor: .center)
          }
        }
      }
    }
    .accessibilityIdentifier("knowledge-library-detail")
  }

  private func header(_ document: KnowledgeDocument) -> some View {
    HStack(spacing: 12) {
      Image(systemName: document.kind.systemImage)
        .font(.title3)
        .foregroundStyle(.tint)
      VStack(alignment: .leading, spacing: 2) {
        Text(document.title)
          .font(.headline)
          .workbenchTruncatedIdentity(document.title)
        Text("仅保存在本机 · \(document.kind.localizedDisplayName)")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()

      Button {
        knowledge.setPinned(!knowledge.isPinned(document.id), documentID: document.id)
      } label: {
        Label(
          knowledge.isPinned(document.id)
            ? String(localized: "取消固定")
            : String(localized: "固定到 AI"),
          systemImage: knowledge.isPinned(document.id) ? "pin.slash" : "pin"
        )
      }

      Menu {
        Button {
          isMetadataEditorPresented = true
        } label: {
          Label("编辑元数据…", systemImage: "pencil")
        }
        Button {
          beginAddingAnnotation(to: document)
        } label: {
          Label("添加资料笔记…", systemImage: "note.text.badge.plus")
        }
        if activeSearchResult != nil {
          Button {
            beginAnnotatingSearchResult(document: document)
          } label: {
            Label("标注当前命中…", systemImage: "highlighter")
          }
        }
        Button {
          isSourceHistoryPresented = true
        } label: {
          Label("来源更新与版本…", systemImage: "clock.arrow.circlepath")
        }
        Divider()
        Toggle(
          String(localized: "允许 AI 检索"),
          isOn: Binding(
            get: { knowledge.selectedDocument?.allowsAIUse ?? false },
            set: { knowledge.setAllowsAIUse($0, documentID: document.id) }
          )
        )
        documentFolderMenu(document)
        Divider()
        Button(role: .destructive) {
          requestDocumentDeletion(document)
        } label: {
          Label(String(localized: "移到回收站"), systemImage: "trash")
        }
      } label: {
        Label(String(localized: "资料操作"), systemImage: "ellipsis.circle")
      }
      .disabled(knowledge.isBusy)

      Button {
        isImportPresented = true
      } label: {
        Label(String(localized: "导入"), systemImage: "plus")
      }
    }
    .padding(.horizontal, 18)
    .padding(.vertical, 12)
  }

  private var deletionConfirmationTitle: String {
    guard let documentPendingDeletion else { return String(localized: "移到回收站？") }
    return String(
      format: String(localized: "将“%@”移到回收站？"),
      documentPendingDeletion.title
    )
  }

  private func requestDocumentDeletion(_ document: KnowledgeDocument) {
    documentPendingDeletion = document
    isDeleteConfirmationPresented = true
  }

  private func confirmDocumentDeletion() {
    guard let document = documentPendingDeletion else { return }
    documentPendingDeletion = nil
    if knowledge.moveToRecycleBin([document.id]) {
      EditorAccessibilityAnnouncementCenter.announce(
        "已将资料移到回收站：\(document.title)。",
        priority: .medium
      )
    }
  }

  private func beginAddingAnnotation(to document: KnowledgeDocument) {
    annotationDraft = KnowledgeAnnotation(
      documentID: document.id,
      revisionID: document.currentRevisionID,
      note: ""
    )
  }

  private func beginAnnotatingSearchResult(document: KnowledgeDocument) {
    guard let result = activeSearchResult else {
      beginAddingAnnotation(to: document)
      return
    }
    annotationDraft = KnowledgeAnnotation(
      documentID: document.id,
      revisionID: result.chunk.revisionID,
      chunkID: result.chunk.id,
      locator: result.chunk.locator?.nilIfEmpty ?? result.chunk.headingPath?.nilIfEmpty,
      highlightedText: String(result.chunk.content.prefix(4_000)),
      note: ""
    )
  }

  private func metadata(_ document: KnowledgeDocument) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Label(
        knowledge.folder(id: document.folderID)?.name ?? "未分类",
        systemImage: document.folderID == nil ? "tray" : "folder"
      )
      Label(
        ByteCountFormatter.string(fromByteCount: document.sourceByteCount, countStyle: .file),
        systemImage: "internaldrive"
      )
      Label(
        "添加于 \(document.importedAt.formatted(date: .abbreviated, time: .shortened))",
        systemImage: "calendar.badge.plus"
      )
      if !document.authors.isEmpty {
        Label(document.authors.joined(separator: "、"), systemImage: "person")
      }
      if let sourceURL = document.sourceURL {
        if sourceURL.isFileURL {
          Label(document.sourceName, systemImage: "link")
            .textSelection(.enabled)
        } else {
          Link(destination: sourceURL) {
            Label(sourceURL.absoluteString, systemImage: "link")
          }
          .buttonStyle(.plain)
          .foregroundStyle(.tint)
        }
      } else if !document.sourceName.isEmpty {
        Label(document.sourceName, systemImage: "archivebox")
      }
      if !document.tags.isEmpty {
        Label(document.tags.joined(separator: "、"), systemImage: "tag")
      }
      Label(
        document.allowsAIUse
          ? String(localized: "允许 AI 检索命中片段")
          : String(localized: "不会提供给 AI"),
        systemImage: document.allowsAIUse ? "sparkles" : "sparkles.slash"
      )
      .foregroundStyle(document.allowsAIUse ? Color.primary : Color.secondary)
    }
    .font(.callout)
  }

  private func documentFolderMenu(_ document: KnowledgeDocument) -> some View {
    Menu("移动到文件夹") {
      Button {
        knowledge.moveDocument(document.id, to: nil)
      } label: {
        Label("未分类", systemImage: document.folderID == nil ? "checkmark" : "tray")
      }
      if !knowledge.folders.isEmpty {
        Divider()
        ForEach(knowledge.folders) { folder in
          Button {
            knowledge.moveDocument(document.id, to: folder.id)
          } label: {
            Label(folder.name, systemImage: document.folderID == folder.id ? "checkmark" : "folder")
          }
        }
      }
    }
  }

  private func searchLocationBanner(_ hit: KnowledgeSearchHitPresentation) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Image(systemName: "scope")
        .foregroundStyle(.tint)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 3) {
        Text("已跳转到命中段落")
          .font(.callout.weight(.semibold))
        HStack(spacing: 6) {
          if let location = hit.locationLabel {
            Text(location)
          }
          Text(hit.reasons.map(\.shortDisplayName).joined(separator: "、"))
        }
        .font(.caption)
        .foregroundStyle(.secondary)
      }
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    .accessibilityElement(children: .combine)
    .accessibilityLabel(
      "已跳转到命中段落，\(hit.locationLabel ?? "正文")，"
        + hit.reasons.map(\.accessibilityDisplayName).joined(separator: "、")
    )
  }

  private var activeSearchResult: KnowledgeSearchResult? {
    guard let result = knowledge.selectedSearchResult,
          result.document.id == knowledge.selectedDocumentID else { return nil }
    return result
  }

  private var activeSearchHit: KnowledgeSearchHitPresentation? {
    activeSearchResult.map {
      KnowledgeSearchPresentationService().presentation(
        for: $0,
        query: knowledge.selectedResultQuery
      )
    }
  }

  private var readerText: String {
    activeSearchResult == nil ? previewText : knowledge.selectedDocumentText
  }

  private var readerBlocks: [KnowledgeDocumentBlock] {
    KnowledgeDocumentBlockParser().blocks(in: readerText)
  }

  private var readerScrollTarget: KnowledgeReaderScrollTarget? {
    guard let result = activeSearchResult,
          let blockID = KnowledgeSearchPresentationService().targetBlockID(
            in: readerBlocks,
            for: result,
            query: knowledge.selectedResultQuery
          ) else { return nil }
    return KnowledgeReaderScrollTarget(resultID: result.id, blockID: blockID)
  }

  private var previewText: String {
    let text = knowledge.selectedDocumentText
    guard text.count > 100_000 else { return text }
    return String(text.prefix(100_000))
  }

}

private struct KnowledgeReaderScrollTarget: Hashable {
  var resultID: UUID
  var blockID: Int
}

private struct KnowledgeDocumentReader: View {
  let blocks: [KnowledgeDocumentBlock]
  let isLoading: Bool
  let errorMessage: String?
  let highlightedBlockID: Int?
  let highlightTerms: [String]
  let retry: () -> Void

  var body: some View {
    if isLoading {
      ProgressView("正在读取…")
        .accessibilityLabel("正在读取…")
    } else if let errorMessage {
      VStack(alignment: .leading, spacing: 8) {
        Label("正文读取失败", systemImage: "exclamationmark.triangle")
          .font(.headline)
          .foregroundStyle(WorkbenchTheme.risk)
        Text(errorMessage)
          .font(.callout)
          .foregroundStyle(.secondary)
        Button("重新读取", action: retry)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    } else if blocks.isEmpty {
      EmptyStateView(
        title: "没有可显示正文",
        message: "资料已保存，但正文为空。可以检查来源版本或重新导入。",
        systemImage: "doc.text.magnifyingglass",
        density: .inline
      )
    } else {
      LazyVStack(alignment: .leading, spacing: 12) {
        ForEach(blocks) { block in
          blockView(block)
            .padding(.horizontal, block.id == highlightedBlockID ? 10 : 0)
            .padding(.vertical, block.id == highlightedBlockID ? 7 : 0)
            .background {
              if block.id == highlightedBlockID {
                RoundedRectangle(cornerRadius: 8)
                  .fill(Color.yellow.opacity(0.13))
                  .overlay {
                    RoundedRectangle(cornerRadius: 8)
                      .stroke(Color.accentColor.opacity(0.45), lineWidth: 1)
                  }
              }
            }
            .accessibilityAddTraits(block.id == highlightedBlockID ? .isSelected : [])
            .id(block.id)
        }
      }
      .tint(.accentColor)
      .textSelection(.enabled)
      .frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityElement(children: .contain)
      .accessibilityLabel("正文")
    }
  }

  @ViewBuilder
  private func blockView(_ block: KnowledgeDocumentBlock) -> some View {
    switch block.kind {
    case .heading(let level):
      inlineText(block.text, isHighlighted: block.id == highlightedBlockID)
        .font(headingFont(level))
        .padding(.top, level <= 2 ? 8 : 4)
        .accessibilityHeading(accessibilityHeadingLevel(level))

    case .paragraph:
      inlineText(block.text, isHighlighted: block.id == highlightedBlockID)
        .font(.body)
        .lineSpacing(3)

    case .quote:
      inlineText(block.text, isHighlighted: block.id == highlightedBlockID)
        .font(.body)
        .foregroundStyle(.secondary)
        .padding(.leading, 12)
        .overlay(alignment: .leading) {
          Rectangle()
            .fill(Color.accentColor.opacity(0.45))
            .frame(width: 2)
            .accessibilityHidden(true)
        }
        .accessibilityLabel("引用：\(block.text)")

    case .unorderedListItem:
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Image(systemName: "circle.fill")
          .font(.system(size: 5))
          .accessibilityHidden(true)
        inlineText(block.text, isHighlighted: block.id == highlightedBlockID)
          .font(.body)
      }
      .accessibilityElement(children: .combine)
      .accessibilityLabel("列表项：\(block.text)")

    case .orderedListItem(let number):
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(verbatim: number.map { "\($0)." } ?? "•")
          .foregroundStyle(.secondary)
          .frame(minWidth: 20, alignment: .trailing)
          .accessibilityHidden(true)
        inlineText(block.text, isHighlighted: block.id == highlightedBlockID)
          .font(.body)
      }
      .accessibilityElement(children: .combine)
      .accessibilityLabel("列表项：\(block.text)")

    case .code(let language):
      VStack(alignment: .leading, spacing: 6) {
        if let language {
          Text(language.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
        }
        KnowledgeHighlightedText.highlightedText(
          block.text,
          terms: block.id == highlightedBlockID ? highlightTerms : []
        )
          .font(.system(.body, design: .monospaced))
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .padding(12)
      .background(
        WorkbenchBackgroundStyle.subtle,
        in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
      )
      .accessibilityElement(children: .combine)
      .accessibilityLabel("代码块：\(block.text)")

    case .locator:
      Label(block.text, systemImage: "mappin.and.ellipse")
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .accessibilityLabel("原文位置：\(block.text)")

    case .separator:
      Divider()
        .accessibilityHidden(true)
    }
  }

  private func inlineText(
    _ text: String,
    isHighlighted: Bool
  ) -> Text {
    let options = AttributedString.MarkdownParsingOptions(
      interpretedSyntax: .inlineOnlyPreservingWhitespace
    )
    let attributed = (try? AttributedString(markdown: text, options: options))
      ?? AttributedString(text)
    guard isHighlighted else { return Text(attributed) }
    return KnowledgeHighlightedText.highlightedText(
      String(attributed.characters),
      terms: highlightTerms
    )
  }

  private func headingFont(_ level: Int) -> Font {
    switch level {
    case 1: .title2.weight(.semibold)
    case 2: .title3.weight(.semibold)
    case 3: .headline
    default: .subheadline.weight(.semibold)
    }
  }

  private func accessibilityHeadingLevel(_ level: Int) -> AccessibilityHeadingLevel {
    switch level {
    case 1: .h1
    case 2: .h2
    case 3: .h3
    case 4: .h4
    case 5: .h5
    default: .h6
    }
  }
}
