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
  static func insertCurrentArticle(
    document: KnowledgeDocument,
    text: String,
    into store: WorkbenchStore
  ) -> Bool {
    let content = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !content.isEmpty else {
      store.setPublishActionMessage("当前资料正文尚未加载完成，请稍后再试。")
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
      store.setPublishActionMessage("当前资料没有可插入的引用片段。")
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
    into store: WorkbenchStore
  ) -> Bool {
    let fragment = RSSArticleWorkflow.safeReferenceMarkdown(
      article: article,
      summary: summary,
      excerpt: excerpt,
      sourceURL: citation?.sourceURL ?? article.link
    )
    let inserted = insert(
      fragment,
      message: "已插入“\(article.title)”的摘要、摘录和来源；未复制全文。",
      into: store
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
      store.setPublishActionMessage("当前 RSS 收藏没有可插入的正文片段。")
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

  static func citation(from pasteboard: NSPasteboard) -> KnowledgeCitation? {
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
      store.setPublishActionMessage("请先创建或选择一篇当前文章。")
      return false
    }

    store.flushDraftBodyEditorBuffer(for: selectedDraft.id)
    guard let draft = store.drafts.first(where: { $0.id == selectedDraft.id }) else {
      store.setPublishActionMessage("当前文章已变化，请重新选择后再插入。")
      return false
    }

    let body = draft.bodyMarkdown
    let bodyNSString = body as NSString
    let range = store.activeEditorSelectionRange(for: draft)
      ?? NSRange(location: bodyNSString.length, length: 0)
    let before = bodyNSString.substring(with: NSRange(location: 0, length: range.location))
    let afterStart = range.location + range.length
    let after = bodyNSString.substring(
      with: NSRange(location: afterStart, length: bodyNSString.length - afterStart)
    )
    let leadingSeparator = before.isEmpty || before.hasSuffix("\n") ? "" : "\n\n"
    let trailingSeparator = after.isEmpty || after.hasPrefix("\n") ? "" : "\n\n"
    let normalizedFragment = fragment.trimmingCharacters(in: .whitespacesAndNewlines)
    let replacement = leadingSeparator + normalizedFragment + trailingSeparator
    let insertedBody = bodyNSString.replacingCharacters(in: range, with: replacement)
    let updatedBody = postProcess?(insertedBody) ?? insertedBody
    let buffer = store.draftBodyEditorBuffer(for: draft.id)
    guard let staged = store.replaceDraftBody(
      updatedBody,
      for: draft.id,
      expectedRevision: buffer.revision
    ), staged.wasAccepted else {
      store.setPublishActionMessage("当前文章在插入前已被其他窗口修改，请重新尝试。")
      return false
    }

    store.save()
    store.selectSection(.writing)
    let insertedLocation = range.location + (leadingSeparator as NSString).length
    store.requestEditorFocus(
      draftID: draft.id,
      field: "body",
      selectedRange: NSRange(
        location: insertedLocation + (normalizedFragment as NSString).length,
        length: 0
      )
    )
    store.setPublishActionMessage(message)
    return true
  }
}
