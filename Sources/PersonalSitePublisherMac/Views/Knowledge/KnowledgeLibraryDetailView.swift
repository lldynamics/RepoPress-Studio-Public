import AppKit
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
  @State private var preparesLocalRepairOnHistoryOpen = false
  @State private var contentPresentation: KnowledgeContentPresentation = .cleaned
  @State private var readerBlocks: [KnowledgeDocumentBlock] = []
  @State private var isParsingReaderBlocks = false
  @State private var isCompactInspectorPopoverPresented = false
  @AppStorage("knowledgeLibraryInspectorVisibleV1") private var isInspectorPresented = true
  @AppStorage(ReaderTypographyConfiguration.fontSizeKey)
  private var readingFontSize = ReaderTypographyConfiguration.defaultFontSize
  @AppStorage(ReaderTypographyConfiguration.lineSpacingKey)
  private var readingLineSpacing = ReaderTypographyConfiguration.defaultLineSpacing
  @AppStorage(ReaderTypographyConfiguration.paragraphSpacingKey)
  private var readingParagraphSpacing = ReaderTypographyConfiguration.defaultParagraphSpacing
  @AppStorage(ReaderTypographyConfiguration.fontFamilyKey)
  private var readingFontFamilyRawValue = ReaderTypographyConfiguration.defaultFontFamily.rawValue
  @AppStorage(ReaderTypographyConfiguration.textAlignmentKey)
  private var readingTextAlignmentRawValue = ReaderTypographyConfiguration.defaultTextAlignment
    .rawValue
  @AppStorage(ReaderTypographyConfiguration.codeHighlightThemeKey)
  private var readingCodeHighlightThemeRawValue = ReaderTypographyConfiguration
    .defaultCodeHighlightTheme.rawValue

  var body: some View {
    Group {
      if let document = knowledge.selectedDocument {
        documentDetail(document)
      } else {
        EmptyStateView(
          title: "资料库",
          message: LocalizedStringKey("导入图片、EPUB 书籍、文章、网页或 PDF，写作和对话时可以按需检索与引用。"),
          systemImage: "books.vertical",
          density: .fullPage,
          actionTitle: knowledge.documents.isEmpty ? "导入资料" : nil,
          actionSystemImage: "tray.and.arrow.down",
          action: knowledge.documents.isEmpty ? { isImportPresented = true } : nil
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
        KnowledgeSourceHistoryView(
          knowledge: knowledge,
          documentID: documentID,
          preparesLocalRepairOnAppear: preparesLocalRepairOnHistoryOpen
        )
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
    .onChange(of: knowledge.selectedDocumentID) { _, _ in
      contentPresentation = .cleaned
    }
    .onChange(of: knowledge.selectedSearchResult?.id) { _, resultID in
      if resultID != nil {
        contentPresentation = .cleaned
      }
    }
    .task(id: readerBlockRequest) {
      await rebuildReaderBlocks(for: readerBlockRequest)
    }
  }

  private func documentDetail(_ document: KnowledgeDocument) -> some View {
    GeometryReader { geometry in
      let isInspectorAvailable = geometry.size.width >= 900
      documentDetailLayout(
        document,
        showsInspector: isInspectorPresented && isInspectorAvailable,
        isInspectorAvailable: isInspectorAvailable
      )
    }
  }

  private func documentDetailLayout(
    _ document: KnowledgeDocument,
    showsInspector: Bool,
    isInspectorAvailable: Bool
  ) -> some View {
    HStack(spacing: 0) {
      VStack(spacing: 0) {
        header(
          document,
          showsInspector: showsInspector,
          isInspectorAvailable: isInspectorAvailable
        )
        Divider()

        ScrollViewReader { proxy in
          ScrollView {
            VStack(alignment: .leading, spacing: 18) {
              metadata(document)
              if showsContentPresentationControl {
                contentPresentationControl
              }
              Divider()
              if let activeSearchHit {
                searchLocationBanner(activeSearchHit)
              }
              if document.kind == .image {
                KnowledgeImageDocumentView(
                  imageURL: knowledge.originalFileURL(documentID: document.id),
                  title: document.title,
                  ocrText: knowledge.selectedDocumentCapturedText
                    ?? knowledge.selectedDocumentText,
                  highlightedAnchor: activeSearchResult?.chunk.visualAnchor
                )
              } else {
                KnowledgeDocumentReader(
                  blocks: readerBlocks,
                  isLoading: isDisplayedContentLoading || isParsingReaderBlocks,
                  errorMessage: displayedContentError,
                  highlightedBlockID: readerScrollTarget?.blockID,
                  highlightTerms: activeSearchHit?.highlightTerms ?? [],
                  fontSize: readingFontSize,
                  lineSpacing: readingLineSpacing,
                  paragraphSpacing: readingParagraphSpacing,
                  fontFamily: selectedReadingFontFamily,
                  textAlignment: selectedReadingTextAlignment,
                  codeHighlightTheme: selectedReadingCodeHighlightTheme,
                  retry: { knowledge.selectDocument(document.id) },
                  onAnnotateBlock: { beginAnnotatingBlock($0, document: document) },
                  onCopyBlockCitation: { copyBlockCitation($0, document: document) }
                )
              }
              if document.kind != .image,
                displayedContentText.count > 100_000,
                activeSearchResult == nil
              {
                HStack(alignment: .center, spacing: 12) {
                  Image(systemName: "doc.text.magnifyingglass")
                    .font(.title3)
                    .foregroundStyle(WorkbenchTheme.info)
                  VStack(alignment: .leading, spacing: 3) {
                    Text(String(localized: "超长文档阅读保护"))
                      .font(.callout.weight(.semibold))
                    Text(contentLimitMessage)
                      .font(.workbenchSupporting)
                      .foregroundStyle(.secondary)
                  }
                  Spacer()
                  if let sourceURL = document.sourceURL {
                    Button {
                      NSWorkspace.shared.open(sourceURL)
                    } label: {
                      Label(String(localized: "在系统默认应用中打开完整源文件"), systemImage: "arrow.up.forward.app")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                  }
                }
                .padding(12)
                .background(WorkbenchBackgroundStyle.card, in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                  RoundedRectangle(cornerRadius: 8)
                    .stroke(WorkbenchTheme.info.opacity(0.2), lineWidth: 1)
                }
              }
            }
            .padding(24)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
          }
          .accessibilityElement(children: .contain)
          .accessibilityIdentifier("knowledge-library-reader")
          .task(id: readerScrollTarget) {
            guard let target = readerScrollTarget else { return }
            await Task.yield()
            proxy.scrollTo(target.blockID, anchor: .center)
          }
        }
      }
      .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)

      if showsInspector {
        Divider()

        KnowledgeLibraryInspectorPanel(
          knowledge: knowledge,
          document: document,
          activeSearchResult: activeSearchResult,
          onEditMetadata: { isMetadataEditorPresented = true },
          onAddAnnotation: { beginAddingAnnotation(to: document) },
          onAnnotateSearchHit: { beginAnnotatingSearchResult(document: document) },
          onEditAnnotation: { annotationDraft = $0 },
          onDeleteAnnotation: { knowledge.deleteAnnotation($0) },
          onOpenSourceHistory: {
            preparesLocalRepairOnHistoryOpen = false
            isSourceHistoryPresented = true
          },
          onReportContentIssue: {
            preparesLocalRepairOnHistoryOpen = true
            isSourceHistoryPresented = true
          }
        )
        .frame(width: 340)
        .frame(maxHeight: .infinity)
        .background(.bar)
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("knowledge-library-detail")
  }

  private func header(
    _ document: KnowledgeDocument,
    showsInspector: Bool,
    isInspectorAvailable: Bool
  ) -> some View {
    HStack(spacing: 12) {
      Image(systemName: document.kind.systemImage)
        .font(.title3)
        .foregroundStyle(.tint)
      VStack(alignment: .leading, spacing: 2) {
        Text(document.title)
          .font(.title3.weight(.semibold))
          .workbenchTruncatedIdentity(document.title)
          .accessibilityElement(children: .ignore)
          .accessibilityLabel(document.title)
          .accessibilityIdentifier("knowledge-library-detail-title")
        Text("仅保存在本机 · \(document.kind.localizedDisplayName)")
          .font(.workbenchSupporting)
          .foregroundStyle(.secondary)
      }
      Spacer()

      if document.kind != .image {
        ReaderTypographyMenu(
          fontSize: $readingFontSize,
          lineSpacing: $readingLineSpacing,
          paragraphSpacing: $readingParagraphSpacing,
          fontFamily: selectedReadingFontFamilyBinding,
          textAlignment: selectedReadingTextAlignmentBinding,
          codeHighlightTheme: selectedReadingCodeHighlightThemeBinding,
          readingTheme: nil,
          accessibilityIdentifier: "knowledge-reader-typography"
        )
        .labelStyle(.iconOnly)
      }

      if isInspectorAvailable {
        Button {
          isInspectorPresented.toggle()
        } label: {
          Label(
            showsInspector ? String(localized: "隐藏检查器") : String(localized: "显示检查器"),
            systemImage: "sidebar.trailing"
          )
        }
        .help(showsInspector ? String(localized: "隐藏资料检查器") : String(localized: "显示资料检查器"))
        .keyboardShortcut("i", modifiers: [.command, .option])
        .accessibilityIdentifier("knowledge-library-inspector-toggle")
      } else {
        Button {
          isCompactInspectorPopoverPresented = true
        } label: {
          Label(String(localized: "资料检查器"), systemImage: "sidebar.trailing")
        }
        .help(String(localized: "查看资料批注与元数据"))
        .accessibilityIdentifier("knowledge-library-inspector-toggle")
        .popover(isPresented: $isCompactInspectorPopoverPresented, arrowEdge: .bottom) {
          KnowledgeLibraryInspectorPanel(
            knowledge: knowledge,
            document: document,
            activeSearchResult: activeSearchResult,
            onEditMetadata: {
              isCompactInspectorPopoverPresented = false
              isMetadataEditorPresented = true
            },
            onAddAnnotation: {
              isCompactInspectorPopoverPresented = false
              beginAddingAnnotation(to: document)
            },
            onAnnotateSearchHit: {
              isCompactInspectorPopoverPresented = false
              beginAnnotatingSearchResult(document: document)
            },
            onEditAnnotation: {
              isCompactInspectorPopoverPresented = false
              annotationDraft = $0
            },
            onDeleteAnnotation: { knowledge.deleteAnnotation($0) },
            onOpenSourceHistory: {
              isCompactInspectorPopoverPresented = false
              preparesLocalRepairOnHistoryOpen = false
              isSourceHistoryPresented = true
            },
            onReportContentIssue: {
              isCompactInspectorPopoverPresented = false
              preparesLocalRepairOnHistoryOpen = true
              isSourceHistoryPresented = true
            }
          )
          .frame(width: 320, height: 460)
        }
      }

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
      .accessibilityIdentifier("knowledge-library-pin-toggle")

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
          preparesLocalRepairOnHistoryOpen = false
          isSourceHistoryPresented = true
        } label: {
          Label("来源更新与版本…", systemImage: "clock.arrow.circlepath")
        }
        Divider()
        Toggle(
          String(localized: "建立本地语义索引"),
          isOn: Binding(
            get: { document.allowsLocalSemanticIndex },
            set: { knowledge.setAllowsLocalSemanticIndex($0, documentID: document.id) }
          )
        )
        Toggle(
          document.kind == .image
            ? String(localized: "允许发送识别文字给远程 AI")
            : String(localized: "允许发送给远程 AI"),
          isOn: Binding(
            get: { document.allowsRemoteAIUse },
            set: { knowledge.setAllowsRemoteAIUse($0, documentID: document.id) }
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
      .accessibilityIdentifier("knowledge-library-actions-menu")

      Button {
        isImportPresented = true
      } label: {
        Label(String(localized: "导入"), systemImage: "plus")
      }
      .accessibilityIdentifier("knowledge-library-import-button")
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

  private func beginAnnotatingBlock(
    _ block: KnowledgeDocumentBlock,
    document: KnowledgeDocument
  ) {
    annotationDraft = KnowledgeAnnotation(
      documentID: document.id,
      revisionID: document.currentRevisionID,
      locator: blockLocator(block),
      highlightedText: String(block.text.prefix(4_000)),
      note: ""
    )
  }

  private func copyBlockCitation(
    _ block: KnowledgeDocumentBlock,
    document: KnowledgeDocument
  ) {
    let location = blockLocator(block)
    let source: String
    if let sourceURL = document.sourceURL, !sourceURL.isFileURL {
      source = "[\(document.title)](\(sourceURL.absoluteString))"
    } else {
      source = document.title
    }
    let citation = "> \(block.text.trimmedForPublishing)\n\n— \(source)，\(location)"
    _ = ClipboardWriter.copy(
      citation,
      successMessage: "已复制“\(document.title)”的引用片段。"
    ) { message in
      EditorAccessibilityAnnouncementCenter.announce(message, priority: .low)
    }
  }

  private func blockLocator(_ block: KnowledgeDocumentBlock) -> String {
    switch block.kind {
    case .heading, .locator:
      return block.text
    default:
      return "正文第 \(block.id + 1) 段"
    }
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
        document.allowsLocalSemanticIndex
          ? String(localized: "已建立本地语义索引")
          : String(localized: "未建立本地语义索引"),
        systemImage: document.allowsLocalSemanticIndex ? "point.3.connected.trianglepath.dotted" : "slash.circle"
      )
      .foregroundStyle(document.allowsLocalSemanticIndex ? Color.primary : Color.secondary)
      Label(
        document.kind == .image
          ? document.allowsRemoteAIUse
            ? String(localized: "允许发送识别文字给远程 AI")
            : String(localized: "禁止发送识别文字给远程 AI")
          : document.allowsRemoteAIUse
            ? String(localized: "允许发送给远程 AI")
            : String(localized: "禁止发送给远程 AI"),
        systemImage: document.allowsRemoteAIUse ? "arrow.up.shield" : "hand.raised"
      )
      .foregroundStyle(document.allowsRemoteAIUse ? Color.primary : Color.secondary)
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

  private var readerScrollTarget: KnowledgeReaderScrollTarget? {
    guard let result = activeSearchResult,
          let blockID = KnowledgeSearchPresentationService().targetBlockID(
            in: readerBlocks,
            for: result,
            query: knowledge.selectedResultQuery
          ) else { return nil }
    return KnowledgeReaderScrollTarget(resultID: result.id, blockID: blockID)
  }

  private var readerBlockRequest: KnowledgeReaderBlockRequest {
    KnowledgeReaderBlockRequest(
      documentID: knowledge.selectedDocumentID,
      revisionID: knowledge.selectedDocument?.currentRevisionID,
      contentPresentation: contentPresentation,
      searchResultID: activeSearchResult?.id,
      isLoading: isDisplayedContentLoading
    )
  }

  @MainActor
  private func rebuildReaderBlocks(
    for request: KnowledgeReaderBlockRequest
  ) async {
    guard knowledge.selectedDocument?.kind != .image else {
      readerBlocks = []
      isParsingReaderBlocks = false
      return
    }
    let limitsPreview = activeSearchResult == nil
    let source = limitsPreview ? displayedContentText : knowledge.selectedDocumentText
    guard !source.isEmpty, !request.isLoading else {
      readerBlocks = []
      isParsingReaderBlocks = false
      return
    }

    isParsingReaderBlocks = true
    let blocks = await Task.detached(priority: .userInitiated) {
      let readerText: String
      if limitsPreview, source.count > 100_000 {
        readerText = String(source.prefix(100_000))
      } else {
        readerText = source
      }
      return KnowledgeDocumentBlockParser().blocks(in: readerText)
    }.value

    guard !Task.isCancelled, readerBlockRequest == request else { return }
    readerBlocks = blocks
    isParsingReaderBlocks = false
  }

  private var showsContentPresentationControl: Bool {
    knowledge.selectedDocument?.kind == .webpage
      && (knowledge.selectedDocumentCapturedText != nil
        || knowledge.isLoadingSelectedDocumentCapturedText
        || knowledge.selectedDocumentCapturedTextError != nil)
  }

  private var contentPresentationControl: some View {
    VStack(alignment: .leading, spacing: 7) {
      HStack(spacing: 8) {
        Picker("正文版本", selection: $contentPresentation) {
          Text("清洗内容").tag(KnowledgeContentPresentation.cleaned)
          Text("原始内容").tag(KnowledgeContentPresentation.original)
        }
        .pickerStyle(.segmented)
        .frame(width: 220)
        .disabled(knowledge.selectedDocumentCapturedText == nil)
        .accessibilityIdentifier("knowledge-library-content-presentation-picker")

        Button {
          preparesLocalRepairOnHistoryOpen = true
          isSourceHistoryPresented = true
        } label: {
          Label(String(localized: "重新清洗…"), systemImage: "wand.and.stars")
        }
        .disabled(knowledge.isBusy || currentRevision == nil)
        .help(String(localized: "使用本机保存的原始网页归档预览新版清洗结果"))
        .accessibilityIdentifier("knowledge-library-reclean-button")
      }

      if let currentRevision,
         currentRevision.parserVersion < KnowledgeLibraryService.parserVersion {
        HStack(alignment: .top, spacing: 8) {
          Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
            .foregroundStyle(WorkbenchTheme.warning)
            .accessibilityHidden(true)
          VStack(alignment: .leading, spacing: 2) {
            Text("清洗规则已升级")
              .font(.callout.weight(.semibold))
            Text(
              String(
                format: String(localized: "当前正文使用清洗规则 v%@，新版 v%@ 可进一步过滤社交平台界面噪声。重新清洗后，阅读、搜索与 AI 检索会改用新版内容。"),
                String(currentRevision.parserVersion),
                String(KnowledgeLibraryService.parserVersion)
              )
            )
            .font(.workbenchSupporting)
            .foregroundStyle(.secondary)
          }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(WorkbenchTheme.warning.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("knowledge-library-cleaning-upgrade-prompt")
      }

      if let error = knowledge.selectedDocumentCapturedTextError {
        Label(
          String(
            format: String(localized: "原始抓取正文读取失败：%@"),
            error
          ),
          systemImage: "exclamationmark.triangle"
        )
          .font(.workbenchSupporting)
          .foregroundStyle(WorkbenchTheme.risk)
      } else {
        Text("清洗内容用于阅读、搜索与 AI 检索；原始抓取正文仅供核对，不会进入 AI 索引。")
          .font(.workbenchSupporting)
          .foregroundStyle(.secondary)
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("knowledge-library-content-presentation")
  }

  private var currentRevision: KnowledgeDocumentRevision? {
    guard let revisionID = knowledge.selectedDocument?.currentRevisionID else { return nil }
    return knowledge.revisions.first { $0.id == revisionID }
  }

  private var displayedContentText: String {
    if contentPresentation == .original,
       let capturedText = knowledge.selectedDocumentCapturedText {
      return capturedText
    }
    return knowledge.selectedDocumentText
  }

  private var isDisplayedContentLoading: Bool {
    contentPresentation == .original
      ? knowledge.isLoadingSelectedDocumentCapturedText
      : knowledge.isLoadingSelectedDocumentText
  }

  private var displayedContentError: String? {
    contentPresentation == .original
      ? knowledge.selectedDocumentCapturedTextError
      : knowledge.selectedDocumentTextError
  }

  private var contentLimitMessage: String {
    contentPresentation == .original
      ? String(localized: "原始抓取正文较长，当前只显示前 100,000 个字符；原文已完整保存。")
      : String(localized: "正文较长，当前详情只显示前 100,000 个字符；全文已完整保存并可检索。")
  }

  private var selectedReadingFontFamily: ReaderFontFamily {
    ReaderFontFamily(rawValue: readingFontFamilyRawValue)
      ?? ReaderTypographyConfiguration.defaultFontFamily
  }

  private var selectedReadingFontFamilyBinding: Binding<ReaderFontFamily> {
    Binding(
      get: { selectedReadingFontFamily },
      set: { readingFontFamilyRawValue = $0.rawValue }
    )
  }

  private var selectedReadingTextAlignment: ReaderTextAlignment {
    ReaderTextAlignment(rawValue: readingTextAlignmentRawValue)
      ?? ReaderTypographyConfiguration.defaultTextAlignment
  }

  private var selectedReadingTextAlignmentBinding: Binding<ReaderTextAlignment> {
    Binding(
      get: { selectedReadingTextAlignment },
      set: { readingTextAlignmentRawValue = $0.rawValue }
    )
  }

  private var selectedReadingCodeHighlightTheme: ReaderCodeHighlightTheme {
    ReaderCodeHighlightTheme(rawValue: readingCodeHighlightThemeRawValue)
      ?? ReaderTypographyConfiguration.defaultCodeHighlightTheme
  }

  private var selectedReadingCodeHighlightThemeBinding: Binding<ReaderCodeHighlightTheme> {
    Binding(
      get: { selectedReadingCodeHighlightTheme },
      set: { readingCodeHighlightThemeRawValue = $0.rawValue }
    )
  }

}

private enum KnowledgeContentPresentation: Hashable {
  case cleaned
  case original
}

private struct KnowledgeReaderBlockRequest: Hashable {
  let documentID: UUID?
  let revisionID: UUID?
  let contentPresentation: KnowledgeContentPresentation
  let searchResultID: UUID?
  let isLoading: Bool
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
  let fontSize: Double
  let lineSpacing: Double
  let paragraphSpacing: Double
  let fontFamily: ReaderFontFamily
  let textAlignment: ReaderTextAlignment
  let codeHighlightTheme: ReaderCodeHighlightTheme
  let retry: () -> Void
  let onAnnotateBlock: (KnowledgeDocumentBlock) -> Void
  let onCopyBlockCitation: (KnowledgeDocumentBlock) -> Void
  @Environment(\.colorScheme) private var colorScheme

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
      LazyVStack(
        alignment: .leading,
        spacing: max(8, normalizedParagraphSpacing * normalizedFontSize)
      ) {
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
            .contextMenu {
              Button {
                onAnnotateBlock(block)
              } label: {
                Label("将本段添加为笔记…", systemImage: "note.text.badge.plus")
              }
              Button {
                onCopyBlockCitation(block)
              } label: {
                Label("复制本段为引用", systemImage: "quote.opening")
              }
            }
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
      readerBodyText(
        block.text,
        isHighlighted: block.id == highlightedBlockID,
        foregroundColor: .labelColor
      )

    case .quote:
      readerBodyText(
        block.text,
        isHighlighted: block.id == highlightedBlockID,
        foregroundColor: .secondaryLabelColor
      )
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
        readerBodyText(
          block.text,
          isHighlighted: block.id == highlightedBlockID,
          foregroundColor: .labelColor
        )
      }
      .accessibilityElement(children: .combine)
      .accessibilityLabel("列表项：\(block.text)")

    case .orderedListItem(let number):
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(verbatim: number.map { "\($0)." } ?? "•")
          .foregroundStyle(.secondary)
          .frame(minWidth: 20, alignment: .trailing)
          .accessibilityHidden(true)
        readerBodyText(
          block.text,
          isHighlighted: block.id == highlightedBlockID,
          foregroundColor: .labelColor
        )
      }
      .accessibilityElement(children: .combine)
      .accessibilityLabel("列表项：\(block.text)")

    case .code(let language):
      let palette = ReaderCodePalette.resolve(
        theme: codeHighlightTheme,
        colorScheme: colorScheme
      )
      VStack(alignment: .leading, spacing: 6) {
        if let language {
          Text(language.uppercased())
            .font(.caption.weight(.semibold))
            .foregroundStyle(palette.comment)
        }
        codeText(block, language: language)
          .font(.body.monospaced())
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .padding(12)
      .background(palette.background, in: RoundedRectangle(cornerRadius: 8))
      .overlay {
        RoundedRectangle(cornerRadius: 8)
          .stroke(palette.border, lineWidth: 1)
      }
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

  @ViewBuilder
  private func readerBodyText(
    _ text: String,
    isHighlighted: Bool,
    foregroundColor: NSColor
  ) -> some View {
    if textAlignment == .justified {
      ReaderJustifiedText(
        markdown: text,
        fontFamily: fontFamily,
        fontSize: normalizedFontSize,
        fontWeight: .regular,
        lineHeightMultiple: normalizedLineSpacing,
        foregroundColor: foregroundColor,
        highlightTerms: isHighlighted ? highlightTerms : []
      )
      .frame(maxWidth: .infinity, alignment: .leading)
    } else {
      inlineText(text, isHighlighted: isHighlighted)
        .font(fontFamily.swiftUIFont(size: normalizedFontSize))
        .lineSpacing(max(0, normalizedFontSize * (normalizedLineSpacing - 1)))
        .foregroundStyle(Color(nsColor: foregroundColor))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func codeText(
    _ block: KnowledgeDocumentBlock,
    language: String?
  ) -> Text {
    if block.id == highlightedBlockID, !highlightTerms.isEmpty {
      return KnowledgeHighlightedText.highlightedText(block.text, terms: highlightTerms)
    }
    return Text(
      ReaderCodeSyntaxHighlighter.attributedString(
        block.text,
        language: language,
        theme: codeHighlightTheme,
        colorScheme: colorScheme
      )
    )
  }

  private func headingFont(_ level: Int) -> Font {
    switch level {
    case 1:
      fontFamily.swiftUIFont(size: max(24, normalizedFontSize * 1.55), weight: .semibold)
    case 2:
      fontFamily.swiftUIFont(size: max(21, normalizedFontSize * 1.32), weight: .semibold)
    case 3:
      fontFamily.swiftUIFont(size: max(18, normalizedFontSize * 1.12), weight: .semibold)
    default: fontFamily.swiftUIFont(size: normalizedFontSize, weight: .semibold)
    }
  }

  private var normalizedFontSize: Double {
    ReaderTypographyConfiguration.normalizedFontSize(fontSize)
  }

  private var normalizedLineSpacing: Double {
    ReaderTypographyConfiguration.normalizedLineSpacing(lineSpacing)
  }

  private var normalizedParagraphSpacing: Double {
    ReaderTypographyConfiguration.normalizedParagraphSpacing(paragraphSpacing)
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
