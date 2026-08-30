import Foundation
import PublishingWorkbenchCore
import XCTest

@testable import PersonalSitePublisherMac

final class RSSArticleSwitchPerformanceRegressionTests: XCTestCase {
  func testProgressPolicyDropsDuplicateEndpointsAndKeepsCompletionThreshold() {
    XCTAssertTrue(RSSReadingProgressPolicy.shouldRecord(previousProgress: nil, progress: 0))
    XCTAssertFalse(RSSReadingProgressPolicy.shouldRecord(previousProgress: 0, progress: 0))
    XCTAssertFalse(RSSReadingProgressPolicy.shouldRecord(previousProgress: 0.50, progress: 0.505))
    XCTAssertTrue(RSSReadingProgressPolicy.shouldRecord(previousProgress: 0.50, progress: 0.51))
    XCTAssertTrue(RSSReadingProgressPolicy.shouldRecord(previousProgress: 0.994, progress: 0.995))
    XCTAssertFalse(RSSReadingProgressPolicy.shouldRecord(previousProgress: 1, progress: 1))
    XCTAssertTrue(RSSReadingProgressPolicy.shouldRecord(previousProgress: 0.994, progress: 1))
  }

  @MainActor
  func testPreparedIndexRevealKeepsPageBoundariesWithoutStoreScan() {
    let state = RSSReaderPresentationState()
    state.revealArticle("article-9999", index: 9_999, totalCount: 10_000)
    XCTAssertEqual(state.articleDisplayLimit, 10_000)

    state.resetArticleDisplayLimit()
    state.revealArticle("out-of-range", index: 10_000, totalCount: 10_000)
    XCTAssertEqual(state.articleDisplayLimit, RSSReaderPresentationState.articlePageSize)
  }

  @MainActor
  func testAIInspectorStaticProjectionStaysCachedForStreamingLeafUpdates() {
    let cache = AIChatInspectorStaticProjectionCache()
    let draftID = UUID()
    let conversationID = UUID()
    let baseKey = AIChatInspectorStaticProjectionCache.Key(
      draftID: draftID,
      draftUpdatedAt: Date(timeIntervalSince1970: 1),
      conversationID: conversationID,
      contextMode: .site,
      conversationTitle: "Conversation",
      firstUserMessageID: UUID(),
      lifecycleRevision: 4,
      siteMaintenanceSnapshotVersion: 7
    )
    let draft = ArticleDraft(siteProfileID: UUID(), title: "Draft", bodyMarkdown: "")
    let makeProjection = {
      AIChatInspectorStaticProjectionCache.Projection(
        draft: draft,
        conversationID: conversationID,
        conversationTitle: "Conversation",
        relatedSuggestions: []
      )
    }

    _ = cache.resolve(key: baseKey, build: makeProjection)
    for _ in 0..<100 {
      _ = cache.resolve(key: baseKey) {
        XCTFail("streaming leaf update rebuilt static inspector context")
        return makeProjection()
      }
    }
    XCTAssertEqual(cache.buildCount, 1)

    let lifecycleKey = AIChatInspectorStaticProjectionCache.Key(
      draftID: baseKey.draftID,
      draftUpdatedAt: baseKey.draftUpdatedAt,
      conversationID: baseKey.conversationID,
      contextMode: baseKey.contextMode,
      conversationTitle: baseKey.conversationTitle,
      firstUserMessageID: baseKey.firstUserMessageID,
      lifecycleRevision: 5,
      siteMaintenanceSnapshotVersion: baseKey.siteMaintenanceSnapshotVersion
    )
    _ = cache.resolve(key: lifecycleKey, build: makeProjection)
    XCTAssertEqual(cache.buildCount, 2)

    let snapshotKey = AIChatInspectorStaticProjectionCache.Key(
      draftID: lifecycleKey.draftID,
      draftUpdatedAt: lifecycleKey.draftUpdatedAt,
      conversationID: lifecycleKey.conversationID,
      contextMode: lifecycleKey.contextMode,
      conversationTitle: lifecycleKey.conversationTitle,
      firstUserMessageID: lifecycleKey.firstUserMessageID,
      lifecycleRevision: lifecycleKey.lifecycleRevision,
      siteMaintenanceSnapshotVersion: 8
    )
    _ = cache.resolve(key: snapshotKey, build: makeProjection)
    XCTAssertEqual(cache.buildCount, 3)
  }

  @MainActor
  func testBackgroundMetricsCanBePublishedWithoutRecomputingOnLookup() {
    let article = RSSArticle(
      id: "metrics-cache",
      feedID: UUID(),
      title: "Metrics cache",
      contentHTML: "<p>正文</p>"
    )
    let state = RSSReaderPresentationState()

    state.cacheReaderMetrics(for: article, hasRenderableBody: false, readingUnits: 880)

    let metrics = state.readerMetrics(for: article)
    XCTAssertFalse(metrics.hasRenderableBody)
    XCTAssertEqual(metrics.readingMinutes, 4)
  }

  func testRenderCacheUsesByteCostAndInvalidatesArticleRevision() throws {
    let cache = RSSArticleHTMLRenderer.RSSArticleRenderCache(costLimit: 20)
    cache.setHTML(String(repeating: "a", count: 12), forKey: "article|revision-1")
    cache.setHTML(String(repeating: "b", count: 12), forKey: "other|revision-1")
    XCTAssertLessThanOrEqual(cache.byteCost, 20)
    XCTAssertNil(cache.html(forKey: "article|revision-1"))

    cache.setHTML("new", forKey: "article|revision-2")
    XCTAssertEqual(cache.count, 2)
    cache.invalidate(articleID: "article")
    XCTAssertNil(cache.html(forKey: "article|revision-2"))
    XCTAssertEqual(cache.byteCost, 12)

    let feedID = UUID()
    var article = RSSArticle(
      id: "render-revision",
      feedID: feedID,
      title: "Original",
      contentHTML: "<p>old body</p>",
      fetchedAt: Date(timeIntervalSince1970: 1)
    )
    let first = RSSArticleHTMLRenderer.render(article: article, allowRemoteImages: false)
    article.title = "Updated"
    article.fetchedAt = Date(timeIntervalSince1970: 2)
    article.contentHTML = "<p>new body</p>"
    let second = RSSArticleHTMLRenderer.render(article: article, allowRemoteImages: false)
    XCTAssertTrue(first.contains("Original"))
    XCTAssertTrue(second.contains("Updated"))
    XCTAssertNotEqual(first, second)
  }

  func testRenderCacheKeyIsStableAndTracksRenderedInputs() throws {
    let article = RSSArticle(
      id: "stable-render-key",
      feedID: UUID(),
      title: "标题",
      link: try XCTUnwrap(URL(string: "https://example.com/article")),
      author: "作者",
      publishedAt: Date(timeIntervalSince1970: 1_700_000_000),
      summaryHTML: "<p>摘要</p>",
      contentHTML: "<p>正文</p>",
      webPageSnapshotHTML: "<p>快照</p>",
      fetchedAt: Date(timeIntervalSince1970: 1_700_000_001)
    )
    let makeKey: (RSSArticle, Bool, Double, RSSReadingTheme) -> String = {
      article,
      allowRemoteImages,
      fontSize,
      theme in
      RSSArticleHTMLRenderer.renderCacheKey(
        article: article,
        feedTitle: "订阅源",
        readingMinutes: 3,
        allowRemoteImages: allowRemoteImages,
        mediaAssets: [],
        mediaCacheDirectoryURL: nil,
        fontSize: fontSize,
        lineSpacing: 1.65,
        paragraphSpacing: ReaderTypographyConfiguration.defaultParagraphSpacing,
        fontFamily: .system,
        textAlignment: .natural,
        codeHighlightTheme: .adaptive,
        theme: theme,
        initialReadingProgress: 0.25
      )
    }

    let key = makeKey(article, false, 17, .system)
    XCTAssertEqual(key, makeKey(article, false, 17, .system))
    XCTAssertTrue(key.hasPrefix("\(article.id)|v2|"))
    XCTAssertEqual(key.split(separator: "|").last?.count, 64)
    let keyCache = RSSArticleHTMLRenderer.RSSArticleRenderCache(costLimit: 64)
    keyCache.setHTML("cached", forKey: key)
    keyCache.invalidate(articleID: article.id)
    XCTAssertNil(keyCache.html(forKey: key))

    var changed = article
    changed.title = "新标题"
    XCTAssertNotEqual(key, makeKey(changed, false, 17, .system))
    changed = article
    changed.link = try XCTUnwrap(URL(string: "https://example.com/other"))
    XCTAssertNotEqual(key, makeKey(changed, false, 17, .system))
    changed = article
    changed.contentHTML = "<p>新正文</p>"
    XCTAssertNotEqual(key, makeKey(changed, false, 17, .system))
    changed = article
    changed.summaryHTML = "<p>新摘要</p>"
    XCTAssertNotEqual(key, makeKey(changed, false, 17, .system))
    changed = article
    changed.webPageSnapshotHTML = "<p>新快照</p>"
    XCTAssertNotEqual(key, makeKey(changed, false, 17, .system))
    XCTAssertNotEqual(key, makeKey(article, true, 17, .system))
    XCTAssertNotEqual(key, makeKey(article, false, 18, .system))
    XCTAssertNotEqual(key, makeKey(article, false, 17, .dark))

    let typographyKey:
      (
        Double,
        ReaderFontFamily,
        ReaderTextAlignment,
        ReaderCodeHighlightTheme
      ) -> String = { paragraphSpacing, fontFamily, textAlignment, codeTheme in
        RSSArticleHTMLRenderer.renderCacheKey(
          article: article,
          feedTitle: "订阅源",
          readingMinutes: 3,
          allowRemoteImages: false,
          mediaAssets: [],
          mediaCacheDirectoryURL: nil,
          fontSize: 17,
          lineSpacing: 1.65,
          paragraphSpacing: paragraphSpacing,
          fontFamily: fontFamily,
          textAlignment: textAlignment,
          codeHighlightTheme: codeTheme,
          theme: .system,
          initialReadingProgress: 0.25
        )
      }
    XCTAssertNotEqual(key, typographyKey(1.1, .system, .natural, .adaptive))
    XCTAssertNotEqual(key, typographyKey(0.82, .newYork, .natural, .adaptive))
    XCTAssertNotEqual(key, typographyKey(0.82, .system, .justified, .adaptive))
    XCTAssertNotEqual(key, typographyKey(0.82, .system, .natural, .solarized))
  }
}
