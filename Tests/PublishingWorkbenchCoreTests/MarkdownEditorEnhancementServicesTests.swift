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
    let revisionID = UUID()
    let chunkID = UUID()
    let citation = KnowledgeCitation(
      id: "K1",
      documentID: documentID,
      revisionID: revisionID,
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

    XCTAssertFalse(result.contains("## 资料来源"))
    XCTAssertFalse(result.contains("第 3 页"))
  }

  func testKnowledgeCitationMarkersKeepDifferentK1SourcesSeparateAcrossReplies() {
    let documentID = UUID()
    let revisionID = UUID()
    let first = KnowledgeCitation(
      id: "K1", documentID: documentID, revisionID: revisionID, chunkID: UUID(),
      title: "资料一", excerpt: "资料一摘录")
    let second = KnowledgeCitation(
      id: "K1", documentID: documentID, revisionID: revisionID, chunkID: UUID(),
      title: "资料二", excerpt: "资料二摘录")
    let existing = KnowledgeCitationMarkdownService.appendingCitations(
      to: "初始结论 [K1]。",
      citations: [first]
    )
    let result = KnowledgeCitationMarkdownService.appendingCitations(
      to: "补充结论 [K1]。\n```text\n[K1]\n```",
      citations: [second],
      existingMarkdown: existing
    )

    XCTAssertTrue(result.contains(KnowledgeCitationMarkdownService.footnoteReference(for: second)))
    XCTAssertTrue(result.contains("```text\n[K1]\n```"))
    XCTAssertFalse(result.contains(KnowledgeCitationMarkdownService.footnoteDefinition(for: first)))
    XCTAssertTrue(result.contains(KnowledgeCitationMarkdownService.footnoteDefinition(for: second)))
  }

  func testKnowledgeCitationMarkersIgnoreMixedLongFencesAndInlineCode() {
    let citation = KnowledgeCitation(
      id: "K1", documentID: UUID(), revisionID: UUID(), chunkID: UUID(),
      title: "资料", excerpt: "摘录")
    let markdown = """
      正文 [K1]，以及 `行内示例 [K1]`。
      ````markdown
      [K1]
      ~~~
      [K1]
      ````
      """

    let result = KnowledgeCitationMarkdownService.appendingCitations(
      to: markdown,
      citations: [citation],
      existingMarkdown:
        "```text\n\(KnowledgeCitationMarkdownService.footnoteDefinition(for: citation))\n```"
    )

    let reference = KnowledgeCitationMarkdownService.footnoteReference(for: citation)
    let prose = result.split(separator: "\n", omittingEmptySubsequences: false)
      .filter { !$0.hasPrefix(reference + ":") }.joined(separator: "\n")
    XCTAssertEqual(prose.components(separatedBy: reference).count - 1, 1)
    XCTAssertTrue(result.contains("`行内示例 [K1]`"))
    XCTAssertTrue(result.contains("````markdown\n[K1]\n~~~\n[K1]\n````"))
    XCTAssertEqual(
      result.components(
        separatedBy: KnowledgeCitationMarkdownService.footnoteDefinition(for: citation)
      ).count - 1, 1)
  }

  func testKnowledgeCitationConflictingMarkerFailsClosedAndSameSourceCanReuseMarkers() {
    let first = KnowledgeCitation(
      id: "K1", documentID: UUID(), revisionID: UUID(), chunkID: UUID(),
      title: "资料一", excerpt: "摘录一")
    let conflicting = KnowledgeCitation(
      id: "K1", documentID: UUID(), revisionID: UUID(), chunkID: UUID(),
      title: "资料二", excerpt: "摘录二")

    let rejected = KnowledgeCitationMarkdownService.appendingCitations(
      to: "冲突 [K1]。",
      citations: [first, conflicting]
    )
    XCTAssertEqual(rejected, "冲突 [K1]。")
    XCTAssertTrue(
      KnowledgeCitationMarkdownService.referencedCitations(
        in: "冲突 [K1]。",
        candidates: [first, conflicting]
      ).isEmpty)

    var sameSource = first
    sameSource.id = "K2"
    let reused = KnowledgeCitationMarkdownService.appendingCitations(
      to: "同源 [K1] 与 [K2]。",
      citations: [first, sameSource]
    )
    let reference = KnowledgeCitationMarkdownService.footnoteReference(for: first)
    let prose = reused.split(separator: "\n", omittingEmptySubsequences: false)
      .filter { !$0.hasPrefix(reference + ":") }.joined(separator: "\n")
    XCTAssertEqual(prose.components(separatedBy: reference).count - 1, 2)
    XCTAssertEqual(
      reused.components(
        separatedBy: KnowledgeCitationMarkdownService.footnoteDefinition(for: first)
      ).count - 1,
      1
    )
    XCTAssertEqual(
      KnowledgeCitationMarkdownService.referencedCitations(
        in: "同源 [K1] 与 [K2]。",
        candidates: [first, sameSource]
      ), [first])
  }

  func testLegacyCitationMarkersRetainDefinitionsForEachLegacyIdentity() {
    let first = KnowledgeCitation(
      id: "K1", documentID: UUID(), chunkID: UUID(), title: "旧资料", excerpt: "摘录")
    var second = first
    second.id = "K2"

    let result = KnowledgeCitationMarkdownService.appendingCitations(
      to: "旧引用 [K1] 与 [K2]。", citations: [first, second])

    for citation in [first, second] {
      XCTAssertEqual(
        result.components(
          separatedBy: KnowledgeCitationMarkdownService.footnoteDefinition(for: citation)
        ).count - 1, 1)
    }
    XCTAssertEqual(
      KnowledgeCitationMarkdownService.referencedCitations(
        in: "旧引用 [K1] 与 [K2]。", candidates: [first, second]), [first, second])
  }

  func testKnowledgeCitationFootnoteReferenceAndDefinitionAreStable() {
    let citation = KnowledgeCitation(
      id: "react-source",
      documentID: UUID(),
      revisionID: UUID(),
      chunkID: UUID(),
      title: "React 官方文档",
      authors: [],
      locator: "Server Components",
      excerpt: "服务端组件可以在服务端执行并向客户端传递结果。",
      sourceURL: URL(string: "https://react.dev/reference/rsc/server-components")
    )

    let key = KnowledgeCitationMarkdownService.footnoteKey(for: citation, fallbackIndex: 1)
    XCTAssertTrue(key.contains("d\(citation.documentID.uuidString.lowercased())"))
    XCTAssertTrue(key.contains("r\(citation.revisionID!.uuidString.lowercased())"))
    XCTAssertTrue(key.contains("c\(citation.chunkID.uuidString.lowercased())"))
    let definition = KnowledgeCitationMarkdownService.footnoteDefinition(for: citation)
    XCTAssertTrue(definition.contains(": React 官方文档"))
    XCTAssertTrue(definition.contains("Server Components"))
    XCTAssertTrue(definition.contains("https://react.dev/reference/rsc/server-components"))
  }

}
