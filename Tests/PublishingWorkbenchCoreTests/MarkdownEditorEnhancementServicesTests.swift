import Foundation
import XCTest

@testable import PublishingWorkbenchCore

final class MarkdownEditorEnhancementServicesTests: XCTestCase {
  func testInternalLinkSuggestionsAndBacklinksStayWithinSite() throws {
    let siteID = UUID()
    var profile = SiteProfile(id: siteID, name: "测试站点")
    profile.applyPublishingDefaults(for: .hugo)
    let current = ArticleDraft(siteProfileID: siteID, title: "当前文章", slug: "current")
    let target = ArticleDraft(
      siteProfileID: siteID,
      title: "发布流程",
      slug: "publish-flow",
      tags: ["Git"],
      summary: "从本地检查到远端发布"
    )
    let otherSite = ArticleDraft(siteProfileID: UUID(), title: "其他站点", slug: "other")
    let source = ArticleDraft(
      siteProfileID: siteID,
      title: "反向引用文章",
      slug: "backlink",
      bodyMarkdown: "阅读[当前文章](/posts/current#setup)了解更多。"
    )

    let suggestions = MarkdownInternalLinkService.suggestions(
      for: current,
      among: [current, target, otherSite, source],
      profile: profile,
      query: "Git"
    )
    XCTAssertEqual(suggestions.map(\.draftID), [target.id])
    XCTAssertEqual(
      MarkdownInternalLinkService.markdownLink(to: try XCTUnwrap(suggestions.first)),
      "[发布流程](/posts/publish-flow/)"
    )
    XCTAssertEqual(
      MarkdownInternalLinkService.backlinks(
        to: current,
        among: [current, target, source],
        profile: profile
      ).map(\.sourceDraftID),
      [source.id]
    )
  }

  func testInternalLinkDestinationUsesJekyllDatedPath() throws {
    let siteID = UUID()
    var profile = SiteProfile(id: siteID, name: "Jekyll 站点")
    profile.applyPublishingDefaults(for: .jekyll)
    let date = try XCTUnwrap(
      Calendar(identifier: .gregorian).date(
        from: DateComponents(
          timeZone: TimeZone(secondsFromGMT: 0),
          year: 2025,
          month: 3,
          day: 4,
          hour: 12
        )
      )
    )
    let draft = ArticleDraft(
      siteProfileID: siteID,
      title: "发布流程",
      date: date,
      slug: "publish-flow"
    )

    XCTAssertEqual(
      MarkdownInternalLinkService.destination(for: draft, profile: profile),
      "/2025/03/04/publish-flow/"
    )
  }

  func testInternalLinkDestinationPrefersImportedRepositoryPath() {
    let siteID = UUID()
    var profile = SiteProfile(id: siteID, name: "Zola 站点")
    profile.applyPublishingDefaults(for: .zola)
    let draft = ArticleDraft(
      siteProfileID: siteID,
      title: "自定义目录文章",
      slug: "configured-slug",
      repositoryPath: "content/notes/custom-topic.md"
    )

    XCTAssertEqual(
      MarkdownInternalLinkService.destination(for: draft, profile: profile),
      "/notes/custom-topic/"
    )
  }

  func testBacklinksRecognizeAbsoluteURLAndIgnoreImageDestination() {
    let siteID = UUID()
    var profile = SiteProfile(id: siteID, name: "Hugo 站点")
    profile.applyPublishingDefaults(for: .hugo)
    let target = ArticleDraft(siteProfileID: siteID, title: "目标文章", slug: "target")
    let absoluteLink = ArticleDraft(
      siteProfileID: siteID,
      title: "完整网址引用",
      slug: "absolute-link",
      bodyMarkdown: "[目标](https://example.com/posts/target/?from=article#summary)"
    )
    let imageOnly = ArticleDraft(
      siteProfileID: siteID,
      title: "图片引用",
      slug: "image-only",
      bodyMarkdown: "![图片](/posts/target/)"
    )

    XCTAssertEqual(
      MarkdownInternalLinkService.backlinks(
        to: target,
        among: [target, absoluteLink, imageOnly],
        profile: profile
      ).map(\.sourceDraftID),
      [absoluteLink.id]
    )
  }

  func testInlineDiagnosticsOfferSafeHeadingAndImageFixes() throws {
    let markdown = "# 标题\n\n### 跳级\n\n![](images/cover-photo.png)\n\n引用[^missing]"
    let diagnostics = MarkdownInlineDiagnosticService.diagnostics(in: markdown)

    XCTAssertTrue(diagnostics.contains { $0.id.hasPrefix("heading-jump") })
    XCTAssertTrue(diagnostics.contains { $0.id.hasPrefix("image-alt") })
    XCTAssertTrue(diagnostics.contains { $0.id.hasPrefix("missing-footnote") && $0.severity == .error })

    let image = try XCTUnwrap(diagnostics.first { $0.id.hasPrefix("image-alt") })
    let edit = try XCTUnwrap(MarkdownInlineDiagnosticService.quickFix(for: image, in: markdown))
    let fixed = (markdown as NSString).replacingCharacters(in: edit.replacedRange, with: edit.replacement)
    XCTAssertTrue(fixed.contains("![cover photo](images/cover-photo.png)"))
  }

  func testInlineDiagnosticsReportUnsafeEmbeddedHTML() {
    let markdown = #"正文 <img src="javascript:alert(1)" onerror="run()">"#

    let diagnostics = MarkdownInlineDiagnosticService.diagnostics(in: markdown)

    XCTAssertTrue(diagnostics.contains { $0.title == CoreL10n.text("HTML 链接已拦截") })
    XCTAssertTrue(diagnostics.contains { $0.message.contains("onerror") && $0.severity == .error })
  }

  func testSnippetExpansionUsesDraftMetadata() throws {
    let draft = ArticleDraft(siteProfileID: UUID(), title: "测试标题", slug: "test-title")
    let template = try XCTUnwrap(
      MarkdownSnippetLibraryService.builtIns.first { $0.id == "template-guide" }
    )
    let expanded = MarkdownSnippetLibraryService.expandedMarkdown(for: template, draft: draft)
    XCTAssertTrue(expanded.hasPrefix("# 测试标题"))
    XCTAssertTrue(expanded.contains("## 操作步骤"))
  }

  func testCustomSnippetsRemainScopedToTheirSiteAndRoundTrip() throws {
    let firstSiteID = UUID()
    let secondSiteID = UUID()
    let saved = MarkdownSnippetLibraryService.savingCustomSnippet(
      title: "发布提醒",
      detail: "发布前检查",
      kind: .snippet,
      markdown: "> {{title}} 发布前请检查链接。",
      siteProfileID: firstSiteID,
      in: []
    )
    let snippet = try XCTUnwrap(saved.first)

    XCTAssertTrue(snippet.isSiteScoped)
    XCTAssertEqual(
      MarkdownSnippetLibraryService.availableSnippets(
        for: firstSiteID,
        customSnippets: saved
      ).last?.id,
      snippet.id
    )
    XCTAssertFalse(
      MarkdownSnippetLibraryService.availableSnippets(
        for: secondSiteID,
        customSnippets: saved
      ).contains(where: { $0.id == snippet.id })
    )

    let snapshot = WorkbenchSnapshot(
      profiles: [SiteProfile(id: firstSiteID, name: "站点")],
      activeProfileID: firstSiteID,
      drafts: [],
      customMarkdownSnippets: saved,
      releaseRecords: []
    )
    let decoded = try JSONDecoder().decode(
      WorkbenchSnapshot.self,
      from: JSONEncoder().encode(snapshot)
    )
    XCTAssertEqual(decoded.customMarkdownSnippets, saved)
  }

  func testSavingCustomSnippetUpdatesExistingEntryWithoutDuplication() throws {
    let siteID = UUID()
    let initial = MarkdownSnippetLibraryService.savingCustomSnippet(
      title: "提示",
      detail: "",
      kind: .snippet,
      markdown: "初始内容",
      siteProfileID: siteID,
      in: []
    )
    let original = try XCTUnwrap(initial.first)
    let updated = MarkdownSnippetLibraryService.savingCustomSnippet(
      id: original.id,
      title: "更新后的提示",
      detail: "编辑后",
      kind: .articleTemplate,
      markdown: "# {{title}}",
      siteProfileID: siteID,
      in: initial
    )

    XCTAssertEqual(updated.count, 1)
    XCTAssertEqual(updated.first?.id, original.id)
    XCTAssertEqual(updated.first?.title, "更新后的提示")
    XCTAssertEqual(updated.first?.kind, .articleTemplate)
  }

  func testDraftNavigationHistorySupportsBackForwardAndBranchReplacement() {
    let first = UUID()
    let second = UUID()
    let third = UUID()
    let replacement = UUID()
    let available = Set([first, second, third, replacement])
    var history = DraftNavigationHistory(currentDraftID: first)

    history.recordVisit(second)
    history.recordVisit(third)
    XCTAssertEqual(history.navigateBackward(availableDraftIDs: available), second)
    XCTAssertEqual(history.navigateBackward(availableDraftIDs: available), first)
    XCTAssertEqual(history.navigateForward(availableDraftIDs: available), second)

    history.recordVisit(replacement)
    XCTAssertFalse(history.canNavigateForward(availableDraftIDs: available))
    XCTAssertEqual(history.navigateBackward(availableDraftIDs: available), second)
  }

  func testDraftNavigationHistorySkipsDeletedArticles() {
    let first = UUID()
    let deleted = UUID()
    let current = UUID()
    var history = DraftNavigationHistory(currentDraftID: first)
    history.recordVisit(deleted)
    history.recordVisit(current)

    XCTAssertEqual(
      history.navigateBackward(availableDraftIDs: Set([first, current])),
      first
    )
  }

  func testKnowledgeCitationsBecomeDeduplicatedFootnotes() {
    let documentID = UUID()
    let chunkID = UUID()
    let citation = KnowledgeCitation(
      id: "1",
      documentID: documentID,
      chunkID: chunkID,
      title: "本地资料",
      authors: ["作者"],
      locator: "第 3 页",
      excerpt: "用于支持结论的摘录。",
      sourceURL: URL(string: "https://example.com/source")
    )
    let result = KnowledgeCitationMarkdownService.appendingCitations(
      to: "AI 生成的正文。",
      citations: [citation, citation]
    )

    XCTAssertTrue(result.contains("## 资料来源"))
    XCTAssertEqual(result.components(separatedBy: "[^kb-1]:").count - 1, 1)
    XCTAssertTrue(result.contains("第 3 页"))
  }

  func testKnowledgeContextQueryUsesDraftMetadataAndHeadings() {
    let draft = ArticleDraft(
      siteProfileID: UUID(),
      title: "React Server Components 实践",
      slug: "react-server-components",
      tags: ["React", "架构"],
      summary: "整理服务端组件的边界与数据流。",
      bodyMarkdown: """
      # React Server Components

      ## 数据获取

      这里讨论服务端渲染、客户端边界和缓存策略。
      """
    )

    let query = KnowledgeContextQueryService.query(
      for: draft,
      maximumCharacters: 600
    )

    XCTAssertTrue(query.contains("标题：React Server Components 实践"))
    XCTAssertTrue(query.contains("摘要：整理服务端组件的边界与数据流。"))
    XCTAssertTrue(query.contains("标签：React、架构"))
    XCTAssertTrue(query.contains("章节：# React Server Components、## 数据获取"))
    XCTAssertTrue(query.contains("服务端渲染、客户端边界和缓存策略"))
  }

  func testKnowledgeContextQueryPrioritizesParagraphAtCaret() {
    let draft = ArticleDraft(
      siteProfileID: UUID(),
      title: "段落上下文",
      slug: "paragraph-context",
      bodyMarkdown: """
      第一段讨论导入流程和资料整理。

      第二段讨论本地语义索引和向量检索。
      """
    )
    let body = draft.bodyMarkdown as NSString
    let caret = body.range(of: "向量检索").location

    let query = KnowledgeContextQueryService.query(
      for: draft,
      selectedRange: NSRange(location: caret, length: 0)
    )

    XCTAssertTrue(query.contains("当前段落：第二段讨论本地语义索引和向量检索。"))
  }

  func testKnowledgeCitationFootnoteReferenceAndDefinitionAreStable() {
    let citation = KnowledgeCitation(
      id: "react-source",
      documentID: UUID(),
      chunkID: UUID(),
      title: "React 官方文档",
      authors: [],
      locator: "Server Components",
      excerpt: "服务端组件可以在服务端执行并向客户端传递结果。",
      sourceURL: URL(string: "https://react.dev/reference/rsc/server-components")
    )

    XCTAssertEqual(
      KnowledgeCitationMarkdownService.footnoteReference(for: citation),
      "[^kb-react-source]"
    )
    let definition = KnowledgeCitationMarkdownService.footnoteDefinition(for: citation)
    XCTAssertTrue(definition.hasPrefix("[^kb-react-source]: React 官方文档"))
    XCTAssertTrue(definition.contains("Server Components"))
    XCTAssertTrue(definition.contains("https://react.dev/reference/rsc/server-components"))
  }

  func testExtendedPreviewExtractsFootnotesAndParsesBasicMermaid() throws {
    let markdown = """
    正文[^a]

    ```mermaid
    flowchart LR
      A[开始] --> B[完成]
    ```

    [^a]: 说明内容
    """
    let blocks = MarkdownExtendedPreviewService.blocks(in: markdown)
    let diagram = try XCTUnwrap(blocks.compactMap { block -> MarkdownMermaidDiagram? in
      if case let .mermaid(diagram) = block { return diagram }
      return nil
    }.first)

    XCTAssertEqual(diagram.direction, .leftRight)
    XCTAssertEqual(diagram.nodes.map(\.label), ["开始", "完成"])
    XCTAssertEqual(diagram.edges.first?.from, "A")
    XCTAssertTrue(blocks.contains { block in
      if case let .markdown(value) = block { return value.contains("### 脚注") }
      return false
    })
  }
}
