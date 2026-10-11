import PublishingAICore
import PublishingKnowledgeCore
import SwiftUI

#if DEBUG
  extension RSSArticleReader {
    struct ToolbarPreviewHost: View {
      private let article = RSSArticle(
        id: "preview-rss-article",
        feedID: UUID(),
        title: "预览：阅读器工具栏",
        link: URL(string: "https://example.com/articles/preview"),
        author: "RepoPress",
        publishedAt: Date(),
        summaryHTML: "<p>检查宽窗口与窄窗口下的工具栏降级。</p>",
        contentHTML: "<p>阅读器工具栏的核心动作应保持可发现，其余动作收纳到更多菜单。</p>"
      )

      var body: some View {
        RSSArticleReader(
          articleHeader: nil,
          article: article,
          isLoading: false,
          loadError: nil,
          feedTitle: "RepoPress RSS",
          feedIconURL: nil,
          highlights: [],
          hasRenderableBody: true,
          readingMinutes: 1,
          allowRemoteImages: .constant(true),
          selectedText: .constant(""),
          readingFontSize: .constant(RSSReadingComfortConfiguration.defaultFontSize),
          readingLineSpacing: .constant(RSSReadingComfortConfiguration.defaultLineSpacing),
          readingParagraphSpacing: .constant(
            ReaderTypographyConfiguration.defaultParagraphSpacing
          ),
          readingFontFamily: .constant(ReaderTypographyConfiguration.defaultFontFamily),
          readingTextAlignment: .constant(ReaderTypographyConfiguration.defaultTextAlignment),
          readingCodeHighlightTheme: .constant(
            ReaderTypographyConfiguration.defaultCodeHighlightTheme
          ),
          readingTheme: .constant(.system),
          readingProgress: 0.42,
          onReadingProgress: { _ in },
          onBack: {},
          onRetryLoad: {},
          onOpenOriginal: {},
          onToggleStarred: {},
          onToggleRead: {},
          onNavigationError: { _ in },
          onBeginHighlight: {},
          onBeginNote: {},
          onEditTags: {},
          onDeleteHighlight: { _ in },
          onSaveToKnowledge: { _ in },
          onAddExcerptNote: { _ in },
          onInsertReference: { _ in },
          onCreateInspirationDraft: { _ in },
          translation: nil,
          translationBackend: .constant(.apple),
          translationTargetCode: .constant("zh-Hans"),
          translationCustomLanguage: .constant(""),
          automaticTranslation: .constant(false),
          isAppleTranslationAvailable: true,
          translationIsRunning: false,
          translationError: nil,
          dataSharingConsent: AIDataSharingConsentPresentation(
            providerName: "预览",
            destination: "本机",
            destinationState: .local,
            isGranted: true
          ),
          onTranslate: { _ in },
          onClearTranslation: {},
          onOpenAISettings: {},
          workflowIsBusy: false,
          isTruncatedCandidate: false,
          isShowingFullText: false,
          isFetchingFullText: false,
          fullTextError: nil,
          isOutsideFilteredResults: false,
          onReturnToResults: {},
          automaticFullTextExtraction: nil,
          onToggleFullText: {},
          onRefreshFullText: {}
        )
        .readerToolbar(for: article, speechArticle: article)
      }
    }
  }

  #Preview("RSS Reader Toolbar") {
    RSSArticleReader.ToolbarPreviewHost()
      .frame(width: 560, height: 72)
      .padding()
  }
#endif
