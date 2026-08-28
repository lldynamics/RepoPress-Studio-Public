import AppKit
import Foundation
import PublishingWorkbenchCore

enum KnowledgeArticleInsertionStyle: String {
  case blockquote
  case footnote
}

@MainActor
enum KnowledgeArticleInsertionService {
  static let knowledgeMarkdownPasteboardType = NSPasteboard.PasteboardType(
    "com.jinfang.repopress.knowledge-markdown"
  )
  static let knowledgeCitationPasteboardType = NSPasteboard.PasteboardType(
    "com.jinfang.repopress.knowledge-citation"
  )

  @discardableResult
  static func insertImage(
    document: KnowledgeDocument,
    selectedResult: KnowledgeSearchResult?,
    knowledge: KnowledgeStore,
    into store: WorkbenchStore
  ) async -> Bool {
    guard document.kind == .image,
      let imageURL = knowledge.originalFileURL(documentID: document.id)
    else {
      store.setPublishActionMessage(
        "资料库图片副本不可读，请先运行资料库健康检查。",
        status: .warning
      )
      return false
    }
    guard let selectedDraft = store.selectedDraft ?? store.ensureEditableDraftSelected() else {
      store.setPublishActionMessage("请先创建或选择一篇当前文章。", status: .warning)
      return false
    }

    store.flushDraftBodyEditorBuffer(for: selectedDraft.id)
    guard let baselineDraft = store.drafts.first(where: { $0.id == selectedDraft.id }) else {
      store.setPublishActionMessage("当前文章已变化，请重新选择后再插入。", status: .warning)
      return false
    }

    let fileStore = store.managedAttachmentFileStore
    var attachment: DraftAttachment
    do {
      attachment = try await store.makeAttachment(
        from: imageURL,
        draft: baselineDraft,
        fileStore: fileStore
      )
      attachment.altText = document.title
    } catch is CancellationError {
      store.setPublishActionMessage("已取消插入图片。", status: .warning)
      return false
    } catch {
      store.setPublishActionMessage(
        "无法把资料图片复制到当前文章：\(error.localizedDescription)",
        status: .failure
      )
      return false
    }

    guard store.selectedDraftID == baselineDraft.id else {
      discardManagedAttachment(attachment, fileStore: fileStore)
      store.setPublishActionMessage(
        "当前文章在图片复制期间已切换，未写入新文章。",
        status: .warning
      )
      return false
    }

    store.flushDraftBodyEditorBuffer(for: baselineDraft.id)
    guard var currentDraft = store.drafts.first(where: { $0.id == baselineDraft.id }) else {
      discardManagedAttachment(attachment, fileStore: fileStore)
      store.setPublishActionMessage("当前文章已不存在，图片未插入。", status: .warning)
      return false
    }

    let markdown = ImageMetadataEditingService().markdownReference(
      altText: document.title,
      imagePath: attachment.relativePublishPath
    )
    let plan = insertionPlan(
      fragment: markdown,
      body: currentDraft.bodyMarkdown,
      range: store.activeEditorSelectionRange(for: currentDraft)
    )
    let buffer = store.draftBodyEditorBuffer(for: currentDraft.id)
    guard
      let staged = store.replaceDraftBody(
        plan.updatedBody,
        for: currentDraft.id,
        expectedRevision: buffer.revision
      ), staged.wasAccepted
    else {
      discardManagedAttachment(attachment, fileStore: fileStore)
      store.setPublishActionMessage(
        "当前文章在插入前已被其他窗口修改，请重新尝试。",
        status: .warning
      )
      return false
    }

    currentDraft.bodyMarkdown = plan.updatedBody
    currentDraft.attachments.append(attachment)
    store.updateDraft(currentDraft)
    store.save()
    store.selectSection(.writing)
    store.requestEditorFocus(
      draftID: currentDraft.id,
      field: "body",
      selectedRange: NSRange(location: plan.cursorLocation, length: 0)
    )
    store.scheduleImageWorkbenchCachesRefresh(for: currentDraft)
    store.setPublishActionMessage(
      "已将“\(document.title)”复制到当前文章附件并插入。",
      status: .success
    )

    if let selectedResult,
      selectedResult.document.id == document.id,
      let citation = makeCitation(
        document: document,
        selectedResult: selectedResult,
        fallbackText: knowledge.selectedDocumentText
      )
    {
      knowledge.recordBacklinks(
        citations: [citation],
        target: KnowledgeBacklinkTarget(
          kind: .articleDraft,
          id: currentDraft.id.uuidString,
          title: currentDraft.title.nilIfEmpty ?? "当前文章",
          location: "正文图片"
        )
      )
    }
    return true
  }

  @discardableResult
  static func insertCurrentArticle(
    document: KnowledgeDocument,
    text: String,
    into store: WorkbenchStore
  ) -> Bool {
    let content = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !content.isEmpty else {
      store.setPublishActionMessage(
        "当前资料正文尚未加载完成，请稍后再试。",
        status: .warning
      )
      return false
    }

    let maximumLength = 100_000
    let truncatedContent = String(content.prefix(maximumLength))
    let truncationNotice = content.count > maximumLength
      ? "\n\n>（资料内容较长，已截取前 \(maximumLength) 个字符。）"
      : ""
    let fragment = "## \(document.title)\n\n\(truncatedContent)\(truncationNotice)"
    return insert(fragment, message: "已将“\(document.title)”插入当前文章。", into: store)
  }

  @discardableResult
  static func insertCitation(
    document: KnowledgeDocument,
    selectedResult: KnowledgeSearchResult?,
    fallbackText: String,
    style: KnowledgeArticleInsertionStyle = .blockquote,
    into store: WorkbenchStore
  ) -> Bool {
    guard let citation = makeCitation(
      document: document,
      selectedResult: selectedResult,
      fallbackText: fallbackText
    ) else {
      store.setPublishActionMessage(
        "当前资料没有可插入的引用片段。",
        status: .warning
      )
      return false
    }

    let fragment = markdownFragment(for: citation, style: style)
    let postProcess: ((String) -> String)? = style == .footnote
      ? { body in
        KnowledgeCitationMarkdownService.appendingCitations(
          to: body,
          citations: [citation]
        )
      }
      : nil

    let inserted = insert(
      fragment,
      message: style == .footnote
        ? "已将“\(document.title)”作为脚手架参考插入当前文章。"
        : "已将“\(document.title)”的引用插入当前文章。",
      into: store,
      postProcess: postProcess
    )
    guard inserted, selectedResult?.document.id == document.id else { return inserted }

    guard let draft = store.selectedDraft else { return inserted }
    store.knowledge.recordBacklinks(
      citations: [citation],
      target: KnowledgeBacklinkTarget(
        kind: .articleDraft,
        id: draft.id.uuidString,
        title: draft.title.nilIfEmpty ?? "当前文章",
        location: "正文"
      )
    )
    return inserted
  }

  @discardableResult
  static func insertRSSReference(
    article: RSSArticle,
    summary: String,
    excerpt: String,
    citation: KnowledgeCitation?,
    appendingFootnote: Bool = false,
    into store: WorkbenchStore
  ) -> Bool {
    let fragment = RSSArticleWorkflow.safeReferenceMarkdown(
      article: article,
      summary: summary,
      excerpt: excerpt,
      sourceURL: citation?.sourceURL ?? article.link
    )
    let postProcess: ((String) -> String)? = appendingFootnote
      ? { body in
        RSSArticleWorkflow.appendingFootnote(
          to: body,
          article: article,
          highlight: nil
        )
      }
      : nil
    let inserted = insert(
      fragment,
      message: "已插入“\(article.title)”的摘要、摘录和来源；未复制全文。",
      into: store,
      postProcess: postProcess
    )
    guard inserted, let citation, let draft = store.selectedDraft else { return inserted }
    store.knowledge.recordBacklinks(
      citations: [citation],
      target: KnowledgeBacklinkTarget(
        kind: .articleDraft,
        id: draft.id.uuidString,
        title: draft.title.nilIfEmpty ?? "当前文章",
        location: "正文"
      )
    )
    return inserted
  }

  @discardableResult
  static func insertRSSContent(
    article: RSSArticle,
    highlight: RSSArticleHighlight?,
    style: KnowledgeArticleInsertionStyle,
    into store: WorkbenchStore
  ) -> Bool {
    let fragment = RSSArticleWorkflow.insertionMarkdown(
      article: article,
      highlight: highlight,
      style: style
    )
    guard !fragment.isEmpty else {
      store.setPublishActionMessage(
        "当前 RSS 收藏没有可插入的正文片段。",
        status: .warning
      )
      return false
    }

    let postProcess: ((String) -> String)? = style == .footnote
      ? { body in
        RSSArticleWorkflow.appendingFootnote(
          to: body,
          article: article,
          highlight: highlight
        )
      }
      : nil
    return insert(
      fragment,
      message: style == .footnote ? "已插入 RSS 脚注。" : "已插入 RSS 引用块。",
      into: store,
      postProcess: postProcess
    )
  }

  static func dragProvider(
    document: KnowledgeDocument,
    selectedResult: KnowledgeSearchResult?,
    fallbackText: String,
    style: KnowledgeArticleInsertionStyle = .blockquote
  ) -> NSItemProvider {
    let citation = makeCitation(
      document: document,
      selectedResult: selectedResult,
      fallbackText: fallbackText
    )
    let markdown = citation.map { markdownFragment(for: $0, style: style) }
      ?? fallbackText.trimmingCharacters(in: .whitespacesAndNewlines)
    let provider = NSItemProvider()
    provider.registerDataRepresentation(
      forTypeIdentifier: knowledgeMarkdownPasteboardType.rawValue,
      visibility: .all
    ) { completion in
      completion(Data(markdown.utf8), nil)
      return nil
    }
    if let citation, let citationData = try? JSONEncoder().encode(citation) {
      provider.registerDataRepresentation(
        forTypeIdentifier: knowledgeCitationPasteboardType.rawValue,
        visibility: .all
      ) { completion in
        completion(citationData, nil)
        return nil
      }
    }
    return provider
  }

  static func rssDragProvider(
    article: RSSArticle,
    highlight: RSSArticleHighlight?,
    style: KnowledgeArticleInsertionStyle
  ) -> NSItemProvider {
    let fragment = RSSArticleWorkflow.insertionMarkdown(
      article: article,
      highlight: highlight,
      style: style
    )
    let markdown = style == .footnote
      ? RSSArticleWorkflow.appendingFootnote(
        to: fragment,
        article: article,
        highlight: highlight
      )
      : fragment
    let provider = NSItemProvider()
    provider.registerDataRepresentation(
      forTypeIdentifier: knowledgeMarkdownPasteboardType.rawValue,
      visibility: .all
    ) { completion in
      completion(Data(markdown.utf8), nil)
      return nil
    }
    return provider
  }

  static func citation(from pasteboard: any MarkdownPasteboardSource) -> KnowledgeCitation? {
    guard let data = pasteboard.data(forType: knowledgeCitationPasteboardType) else {
      return nil
    }
    return try? JSONDecoder().decode(KnowledgeCitation.self, from: data)
  }

  static func markdownFragment(
    document: KnowledgeDocument,
    selectedResult: KnowledgeSearchResult?,
    fallbackText: String,
    style: KnowledgeArticleInsertionStyle = .blockquote
  ) -> String? {
    guard let citation = makeCitation(
      document: document,
      selectedResult: selectedResult,
      fallbackText: fallbackText
    ) else {
      return nil
    }
    return markdownFragment(for: citation, style: style)
  }

  private static func makeCitation(
    document: KnowledgeDocument,
    selectedResult: KnowledgeSearchResult?,
    fallbackText: String
  ) -> KnowledgeCitation? {
    let result = selectedResult?.document.id == document.id ? selectedResult : nil
    let excerpt = (result?.chunk.content ?? fallbackText)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !excerpt.isEmpty else { return nil }

    let excerptForMarkdown = String(excerpt.prefix(1_200))
    let locator = result?.chunk.locator?.nilIfEmpty
      ?? result?.chunk.headingPath?.nilIfEmpty
      ?? "资料正文"
    let documentIDPrefix = String(document.id.uuidString.prefix(8))
    let chunkIDPrefix = result.map { String($0.chunk.id.uuidString.prefix(8)) } ?? "excerpt"
    return KnowledgeCitation(
      id: documentIDPrefix + "-" + chunkIDPrefix,
      documentID: document.id,
      chunkID: result?.chunk.id ?? UUID(),
      title: document.title,
      authors: document.authors,
      locator: locator,
      excerpt: excerptForMarkdown,
      sourceURL: document.sourceURL
    )
  }

  private static func markdownFragment(
    for citation: KnowledgeCitation,
    style: KnowledgeArticleInsertionStyle
  ) -> String {
    switch style {
    case .blockquote:
      let quote = citation.excerpt
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map { "> \($0)" }
        .joined(separator: "\n")
      let source = citation.sourceURL.map {
        "[\(citation.title)](\($0.absoluteString))"
      } ?? citation.title
      return "\(quote)\n>\n> — \(source)，\(citation.locator ?? "资料正文")"
    case .footnote:
      return KnowledgeCitationMarkdownService.footnoteReference(for: citation)
    }
  }

  @discardableResult
  private static func insert(
    _ fragment: String,
    message: String,
    into store: WorkbenchStore,
    postProcess: ((String) -> String)? = nil
  ) -> Bool {
    guard let selectedDraft = store.selectedDraft ?? store.ensureEditableDraftSelected() else {
      store.setPublishActionMessage(
        "请先创建或选择一篇当前文章。",
        status: .warning
      )
      return false
    }

    store.flushDraftBodyEditorBuffer(for: selectedDraft.id)
    guard let draft = store.drafts.first(where: { $0.id == selectedDraft.id }) else {
      store.setPublishActionMessage(
        "当前文章已变化，请重新选择后再插入。",
        status: .warning
      )
      return false
    }

    let plan = insertionPlan(
      fragment: fragment,
      body: draft.bodyMarkdown,
      range: store.activeEditorSelectionRange(for: draft)
    )
    let updatedBody = postProcess?(plan.updatedBody) ?? plan.updatedBody
    let buffer = store.draftBodyEditorBuffer(for: draft.id)
    guard let staged = store.replaceDraftBody(
      updatedBody,
      for: draft.id,
      expectedRevision: buffer.revision
    ), staged.wasAccepted else {
      store.setPublishActionMessage(
        "当前文章在插入前已被其他窗口修改，请重新尝试。",
        status: .warning
      )
      return false
    }

    store.save()
    store.selectSection(.writing)
    store.requestEditorFocus(
      draftID: draft.id,
      field: "body",
      selectedRange: NSRange(
        location: plan.cursorLocation,
        length: 0
      )
    )
    store.setPublishActionMessage(message, status: .success)
    return true
  }

  private static func insertionPlan(
    fragment: String,
    body: String,
    range requestedRange: NSRange?
  ) -> (updatedBody: String, cursorLocation: Int) {
    let bodyNSString = body as NSString
    let range: NSRange
    if let requestedRange, requestedRange.location != NSNotFound {
      let location = min(max(0, requestedRange.location), bodyNSString.length)
      let length = min(max(0, requestedRange.length), bodyNSString.length - location)
      range = NSRange(location: location, length: length)
    } else {
      range = NSRange(location: bodyNSString.length, length: 0)
    }
    let before = bodyNSString.substring(with: NSRange(location: 0, length: range.location))
    let afterStart = range.location + range.length
    let after = bodyNSString.substring(
      with: NSRange(location: afterStart, length: bodyNSString.length - afterStart)
    )
    let leadingSeparator = before.isEmpty || before.hasSuffix("\n") ? "" : "\n\n"
    let trailingSeparator = after.isEmpty || after.hasPrefix("\n") ? "" : "\n\n"
    let normalizedFragment = fragment.trimmingCharacters(in: .whitespacesAndNewlines)
    let replacement = leadingSeparator + normalizedFragment + trailingSeparator
    return (
      bodyNSString.replacingCharacters(in: range, with: replacement),
      range.location
        + (leadingSeparator as NSString).length
        + (normalizedFragment as NSString).length
    )
  }

  private static func discardManagedAttachment(
    _ attachment: DraftAttachment,
    fileStore: ManagedAttachmentFileStore
  ) {
    guard let sourcePath = attachment.sourceFilePath?.nilIfEmpty else { return }
    do {
      try fileStore.discardStoredFile(at: URL(fileURLWithPath: sourcePath))
    } catch {
      // Cleanup is best effort after the body mutation has already been rejected.
    }
  }
}
