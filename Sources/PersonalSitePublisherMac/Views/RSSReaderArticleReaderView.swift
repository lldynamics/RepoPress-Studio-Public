import AppKit
import PublishingWorkbenchCore
import SwiftUI

struct RSSArticleReader: View {
  let articleHeader: RSSArticleHeader?
  let article: RSSArticle?
  let isLoading: Bool
  let loadError: String?
  let feedTitle: String?
  let feedIconURL: URL?
  let highlights: [RSSArticleHighlight]
  let hasRenderableBody: Bool
  let readingMinutes: Int
  @Binding var allowRemoteImages: Bool
  @Binding var selectedText: String
  @Binding var readingFontSize: Double
  @Binding var readingLineSpacing: Double
  @Binding var readingTheme: RSSReadingTheme
  let readingProgress: Double
  let onReadingProgress: (Double) -> Void
  let onBack: (() -> Void)?
  let onRetryLoad: () -> Void
  let onOpenOriginal: () -> Void
  let onToggleStarred: () -> Void
  let onToggleRead: () -> Void
  let onNavigationError: (String) -> Void
  let onBeginHighlight: () -> Void
  let onBeginNote: () -> Void
  let onEditTags: () -> Void
  let onDeleteHighlight: (UUID) -> Void
  let onSaveToKnowledge: (RSSArticle) -> Void
  let onAddExcerptNote: (RSSArticle) -> Void
  let onInsertReference: (RSSArticle) -> Void
  let onCreateInspirationDraft: (RSSArticle) -> Void
  let translation: RSSArticleTranslationResult?
  @Binding var translationTargetCode: String
  @Binding var translationCustomLanguage: String
  @Binding var automaticTranslation: Bool
  let translationIsRunning: Bool
  let translationError: String?
  let dataSharingConsent: AIDataSharingConsentPresentation
  let onTranslate: () -> Void
  let onClearTranslation: () -> Void
  let onOpenAISettings: () -> Void
  let workflowIsBusy: Bool
  let isTruncatedCandidate: Bool
  let isShowingFullText: Bool
  let isFetchingFullText: Bool
  let fullTextError: String?
  let automaticFullTextExtraction: Binding<Bool>?
  let onToggleFullText: () -> Void
  @State private var showsTranslatedArticle = false
  @State private var showsAnnotationSummary = false
  @StateObject private var speechController = RSSArticleSpeechController()

  var body: some View {
    Group {
      if let article {
        loadedArticleView(article)
      } else if let articleHeader {
        ScrollView {
          VStack(alignment: .leading, spacing: 18) {
            if let onBack {
              Button("返回文章列表", systemImage: "chevron.left", action: onBack)
                .buttonStyle(.borderless)
            }
            Text(articleHeader.title)
              .font(.workbenchPageTitle)
              .fixedSize(horizontal: false, vertical: true)
              .accessibilityIdentifier("rss-reader-detail")
            HStack(spacing: 8) {
              feedIcon
              Label(feedTitle ?? "RSS", systemImage: "dot.radiowaves.left.and.right")
              if let date = articleHeader.publishedAt {
                Label(date.formatted(date: .abbreviated, time: .shortened), systemImage: "calendar")
              }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            readingProgressLabel
            Divider()
            if isLoading {
              ProgressView("正在读取本机正文…")
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
              Text(loadError ?? "暂时无法读取这篇文章的本机正文。")
                .foregroundStyle(WorkbenchTheme.risk)
              HStack(spacing: 8) {
                Button("重试读取", systemImage: "arrow.clockwise", action: onRetryLoad)
                  .workbenchProminentActionStyle()
                if articleHeader.link != nil {
                  Button("打开原文", systemImage: "safari", action: onOpenOriginal)
                    .buttonStyle(.bordered)
                }
              }
            }
          }
          .padding(WorkbenchSpacing.spacious)
          .frame(maxWidth: 900, alignment: .leading)
          .frame(maxWidth: .infinity, alignment: .center)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("RSS 文章正文正在读取")
      } else {
        RSSReaderEmptyState(
          title: "选择一篇文章",
          message: "从左侧文章列表选择内容，正文会在这里完整显示。",
          systemImage: "text.book.closed"
        )
        .accessibilityIdentifier("rss-reader-detail")
      }
    }
    .accessibilityElement(children: .contain)
    .onAppear {
      showsTranslatedArticle = translation != nil
    }
    .onChange(of: article?.id) { _, _ in
      showsTranslatedArticle = false
      showsAnnotationSummary = false
      selectedText = ""
      speechController.stop()
    }
    .onChange(of: showsTranslatedArticle) { _, _ in
      speechController.stop()
    }
    .onChange(of: translation?.id) { _, newValue in
      showsTranslatedArticle = newValue != nil
      speechController.stop()
    }
    .onDisappear {
      speechController.stop()
    }
  }

  private func loadedArticleView(_ article: RSSArticle) -> some View {
    let displayedArticle = articleForDisplay(article)
    return ZStack(alignment: .top) {
      if !hasRenderableBody {
        VStack(alignment: .leading) {
          Text("这篇文章没有可显示的正文，建议打开原文阅读。")
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("rss-reader-detail")
          Spacer(minLength: 0)
        }
        .padding(WorkbenchSpacing.spacious)
        .frame(maxWidth: 900, maxHeight: .infinity, alignment: .topLeading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
      } else {
        RSSArticleWebView(
          article: displayedArticle,
          feedTitle: feedTitle,
          readingMinutes: readingMinutes,
          allowRemoteImages: allowRemoteImages,
          highlights: highlights,
          fontSize: readingFontSize,
          lineSpacing: readingLineSpacing,
          theme: readingTheme,
          initialReadingProgress: readingProgress,
          renderRevision: showsTranslatedArticle
            ? translation?.id ?? "translated"
            : "source-\(article.fetchedAt.timeIntervalSinceReferenceDate)",
          speechHighlight: speechController.currentArticleID == displayedArticle.id
            ? speechController.currentSpeechHighlight
            : nil,
          onSelectionChanged: { value in
            guard articleHeader?.id == article.id else { return }
            selectedText = value
          },
          onReadingProgress: onReadingProgress,
          onNavigationError: { message in
            guard articleHeader?.id == article.id else { return }
            selectedText = ""
            onNavigationError(message)
          }
        )
        .frame(minHeight: 240, maxHeight: .infinity)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .layoutPriority(1)
        .accessibilityIdentifier("rss-reader-detail")
        .overlay(alignment: .top) {
          if hasSelectedText {
            ReaderContextualSelectionBar(
              selectedText: selectedText,
              onExplain: { text in
                EditorAccessibilityAnnouncementCenter.announce("AI 正在解释：\(text.prefix(20))")
              },
              onTranslate: { _ in
                onTranslate()
              },
              onHighlight: { _ in
                onBeginHighlight()
              },
              onQuoteToDraft: { _ in
                onCreateInspirationDraft(article)
              },
              onSpeak: { _ in
                speechController.toggle(article: article)
              }
            )
            .padding(.top, 60)
            .transition(
              .asymmetric(
                insertion: .move(edge: .top).combined(with: .opacity),
                removal: .opacity
              )
            )
            .animation(.easeInOut(duration: 0.15), value: hasSelectedText)
            .zIndex(3)
          }
        }
        .accessibilityLabel("保留标题、列表、引用、代码块和链接的文章正文")

        VStack(spacing: 4) {
          readingProgressBar
          readerToolbar(for: article, speechArticle: displayedArticle)
          fullTextStatusBanner(for: article)
          translationStatusView
        }
        .background(.thinMaterial)
        .zIndex(1)
        .frame(maxWidth: 900)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 8)
        .padding(.top, 6)
      }
      if isStaleOrLoading(article) {
        readerLoadingOverlay(for: article)
          .zIndex(10)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("RSS 文章阅读区域")
  }

  private func isStaleOrLoading(_ article: RSSArticle) -> Bool {
    isLoading || loadError != nil || articleHeader?.id != article.id
  }

  @ViewBuilder
  private func readerLoadingOverlay(for article: RSSArticle) -> some View {
    let showsLoading = loadError == nil && (isLoading || articleHeader?.id != article.id)
    ZStack {
      Color(nsColor: .windowBackgroundColor)
        .ignoresSafeArea()
      VStack(alignment: .leading, spacing: 12) {
        if showsLoading {
          ProgressView()
            .controlSize(.small)
          Text("正在读取本机正文…")
            .font(.headline)
        } else {
          Label("无法读取这篇文章的本机正文。", systemImage: "exclamationmark.triangle")
            .font(.headline)
            .foregroundStyle(WorkbenchTheme.risk)
          if let loadError, !loadError.isEmpty {
            Text(loadError)
              .font(.callout)
              .foregroundStyle(.secondary)
              .textSelection(.enabled)
          }
          HStack(spacing: 8) {
            Button("重试读取", systemImage: "arrow.clockwise", action: onRetryLoad)
              .workbenchProminentActionStyle()
            if articleHeader?.link != nil {
              Button("打开原文", systemImage: "safari", action: onOpenOriginal)
                .buttonStyle(.bordered)
            }
          }
        }
      }
      .padding(WorkbenchSpacing.spacious)
      .frame(maxWidth: 560, alignment: .leading)
    }
    .contentShape(Rectangle())
    .allowsHitTesting(true)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(showsLoading ? "正在读取当前 RSS 文章正文" : "RSS 文章正文读取失败")
  }

  private var readingProgressBar: some View {
    GeometryReader { geometry in
      ZStack(alignment: .leading) {
        Rectangle()
          .fill(Color.primary.opacity(0.10))
        Rectangle()
          .fill(Color.accentColor.opacity(0.85))
          .frame(width: geometry.size.width * normalizedReadingProgress)
      }
    }
    .frame(height: 2)
    .allowsHitTesting(false)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("阅读进度")
    .accessibilityValue("已读 \(readingProgressPercentage)%")
    .accessibilityIdentifier("rss-reading-progress-bar")
  }

  private func articleForDisplay(_ article: RSSArticle) -> RSSArticle {
    guard showsTranslatedArticle, let translation else { return article }
    return translation.applying(to: article)
  }

  private var readingProgressLabel: some View {
    Text("已读 \(readingProgressPercentage)%")
      .font(.caption.weight(.medium))
      .foregroundStyle(Color.accentColor)
      .help("阅读进度：已读 \(readingProgressPercentage)%")
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("阅读进度")
      .accessibilityValue("已读 \(readingProgressPercentage)%")
  }

  private var normalizedReadingProgress: Double {
    min(max(readingProgress, 0), 1)
  }

  private var readingProgressPercentage: Int {
    Int((normalizedReadingProgress * 100).rounded())
  }

  @ViewBuilder
  private func fullTextStatusBanner(for article: RSSArticle) -> some View {
    if isFetchingFullText {
      HStack(spacing: 6) {
        ProgressView().controlSize(.small)
        Text(String(localized: "正在从原站提取全文…"))
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .frame(maxWidth: .infinity, alignment: .leading)
    } else if let error = fullTextError {
      HStack(spacing: 6) {
        Image(systemName: "exclamationmark.circle")
          .foregroundStyle(WorkbenchTheme.risk)
        Text(String(localized: "提取全文失败：\(error)"))
          .font(.caption)
          .foregroundStyle(WorkbenchTheme.risk)
          .lineLimit(1)
        Spacer()
        Button(String(localized: "重试"), action: onToggleFullText)
          .buttonStyle(.borderless)
          .font(.caption.weight(.medium))
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .background(WorkbenchTheme.risk.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
      .frame(maxWidth: .infinity, alignment: .leading)
    } else if isTruncatedCandidate && !isShowingFullText {
      HStack(spacing: 8) {
        Label(String(localized: "当前为截断摘要，可提取原站全文阅读"), systemImage: "doc.text.magnifyingglass")
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        Button {
          onToggleFullText()
        } label: {
          Label(String(localized: "提取全文"), systemImage: "sparkles")
            .font(.caption.weight(.medium))
        }
        .workbenchProminentActionStyle()
        .controlSize(.small)
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
      .frame(maxWidth: .infinity, alignment: .leading)
    } else if isShowingFullText {
      HStack(spacing: 6) {
        Image(systemName: "checkmark.seal.fill")
          .foregroundStyle(WorkbenchTheme.progress)
        Text(String(localized: "已加载原站全文"))
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        Button(String(localized: "恢复原始摘要"), action: onToggleFullText)
          .buttonStyle(.borderless)
          .font(.caption)
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 3)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  @ViewBuilder
  private var translationStatusView: some View {
    if translationIsRunning || translationError != nil || translation != nil {
      VStack(alignment: .leading, spacing: 5) {
        if translationIsRunning {
          HStack(spacing: 7) {
            ProgressView()
              .controlSize(.small)
            Text("正在翻译标题和正文…")
          }
          .font(.caption)
          .accessibilityElement(children: .combine)
          .accessibilityLabel("正在翻译当前 RSS 文章的标题和正文")
        }
        if let translationError {
          Label(translationError, systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(WorkbenchTheme.risk)
            .lineLimit(3)
            .help(translationError)
            .textSelection(.enabled)
        }
        if let translation {
          HStack(alignment: .firstTextBaseline, spacing: 6) {
            Label(
              "已生成 \(localizedTranslationTargetName(translation.target)) 译文 · \(translation.providerName)",
              systemImage: showsTranslatedArticle ? "character.book.closed" : "doc.plaintext"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            if translation.wasInputTruncated {
              Text("（源文过长，已按安全上限截取）")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
          .lineLimit(2)
        }
      }
      .accessibilityElement(children: .contain)
      .accessibilityLabel("RSS 翻译状态")
    }
  }

  private func localizedTranslationTargetName(
    _ target: RSSArticleTranslationTarget
  ) -> String {
    switch target.languageCode {
    case RSSArticleTranslationTarget.simplifiedChinese.languageCode:
      return String(localized: "简体中文")
    case RSSArticleTranslationTarget.traditionalChinese.languageCode:
      return String(localized: "繁体中文")
    case RSSArticleTranslationTarget.english.languageCode:
      return String(localized: "English")
    case RSSArticleTranslationTarget.japanese.languageCode:
      return String(localized: "日语")
    case RSSArticleTranslationTarget.korean.languageCode:
      return String(localized: "韩语")
    case RSSArticleTranslationTarget.spanish.languageCode:
      return String(localized: "西班牙语")
    case RSSArticleTranslationTarget.french.languageCode:
      return String(localized: "法语")
    case RSSArticleTranslationTarget.german.languageCode:
      return String(localized: "德语")
    default:
      let prefix = "custom:"
      guard target.languageCode.hasPrefix(prefix) else { return target.languageCode }
      return String(target.languageCode.dropFirst(prefix.count))
    }
  }

  @ViewBuilder
  private var feedIcon: some View {
    if let feedIconURL {
      AsyncImage(url: feedIconURL) { phase in
        if let image = phase.image {
          image.resizable().scaledToFill()
        } else {
          Image(systemName: "dot.radiowaves.left.and.right")
        }
      }
      .frame(width: 20, height: 20)
      .clipShape(RoundedRectangle(cornerRadius: 4))
      .accessibilityLabel("来源图标")
    }
  }

  @ViewBuilder
  private func articleMetadata(for article: RSSArticle) -> some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 8) {
        feedIcon
        Label(feedTitle ?? "RSS", systemImage: "dot.radiowaves.left.and.right")
        if let author = article.author?.trimmedForPublishing.nilIfEmpty {
          Label(author, systemImage: "person")
        }
        if let date = article.publishedAt {
          Label(date.formatted(date: .abbreviated, time: .shortened), systemImage: "calendar")
        }
        Label("约 \(readingMinutes) 分钟", systemImage: "clock")
      }
      VStack(alignment: .leading, spacing: 5) {
        HStack(spacing: 8) {
          feedIcon
          Label(feedTitle ?? "RSS", systemImage: "dot.radiowaves.left.and.right")
          if let author = article.author?.trimmedForPublishing.nilIfEmpty {
            Label(author, systemImage: "person")
          }
        }
        HStack(spacing: 8) {
          if let date = article.publishedAt {
            Label(date.formatted(date: .abbreviated, time: .shortened), systemImage: "calendar")
          }
          Label("约 \(readingMinutes) 分钟", systemImage: "clock")
        }
      }
    }
  }

  @ViewBuilder
  private func readerToolbar(
    for article: RSSArticle,
    speechArticle: RSSArticle
  ) -> some View {
    ViewThatFits(in: .horizontal) {
      readerToolbarExpandedContent(for: article, speechArticle: speechArticle)
      readerToolbarMediumContent(for: article, speechArticle: speechArticle)
      readerToolbarCompactContent(for: article, speechArticle: speechArticle)
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 4)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
    .overlay {
      RoundedRectangle(cornerRadius: 9)
        .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .controlSize(.small)
    .popover(isPresented: $showsAnnotationSummary, arrowEdge: .bottom) {
      annotationSummary(for: article)
    }
  }

  @ViewBuilder
  private func readerToolbarExpandedContent(
    for article: RSSArticle,
    speechArticle: RSSArticle
  ) -> some View {
    HStack(alignment: .center, spacing: 6) {
      readerBackButton
      starredButton(for: article)
      readButton(for: article)
      if article.link != nil {
        fullTextButton(for: article)
      }
      Divider().frame(height: 14)
      speechToggleButton(for: speechArticle)
      if speechController.currentArticleID == speechArticle.id && speechController.isSpeaking {
        speechRateMenu
      }
      translationControls
      readingComfortControls
      annotationSummaryButton(for: article)
      workflowIntegrationMenu(for: article)
      if article.link != nil {
        originalArticleButton(for: article)
      }
      readerOverflowMenu(for: article, speechArticle: speechArticle)
      readerToolbarBusyIndicator
    }
  }

  @ViewBuilder
  private func readerToolbarMediumContent(
    for article: RSSArticle,
    speechArticle: RSSArticle
  ) -> some View {
    HStack(alignment: .center, spacing: 6) {
      readerBackButton
      starredButton(for: article)
        .labelStyle(.iconOnly)
      readButton(for: article)
        .labelStyle(.iconOnly)
      if article.link != nil {
        fullTextButton(for: article)
          .labelStyle(.iconOnly)
      }
      Divider().frame(height: 14)
      speechToggleButton(for: speechArticle)
        .labelStyle(.iconOnly)
      if speechController.currentArticleID == speechArticle.id && speechController.isSpeaking {
        speechRateMenu
      }
      translationControls
        .labelStyle(.iconOnly)
      readingComfortControls
        .labelStyle(.iconOnly)
      annotationSummaryButton(for: article)
        .labelStyle(.iconOnly)
      workflowIntegrationMenu(for: article)
        .labelStyle(.iconOnly)
      if article.link != nil {
        originalArticleButton(for: article)
          .labelStyle(.iconOnly)
      }
      readerOverflowMenu(for: article, speechArticle: speechArticle)
        .labelStyle(.iconOnly)
      readerToolbarBusyIndicator
    }
  }

  @ViewBuilder
  private func readerToolbarCompactContent(
    for article: RSSArticle,
    speechArticle: RSSArticle
  ) -> some View {
    HStack(alignment: .center, spacing: 6) {
      readerBackButton
      starredButton(for: article)
        .labelStyle(.iconOnly)
      readButton(for: article)
        .labelStyle(.iconOnly)
      if article.link != nil {
        fullTextButton(for: article)
          .labelStyle(.iconOnly)
      }
      if article.link != nil {
        originalArticleButton(for: article)
          .labelStyle(.iconOnly)
      }
      readerOverflowMenu(for: article, speechArticle: speechArticle)
        .labelStyle(.iconOnly)
      readerToolbarBusyIndicator
    }
  }

  @ViewBuilder
  private func fullTextButton(for article: RSSArticle) -> some View {
    if isShowingFullText {
      Button {
        onToggleFullText()
      } label: {
        Label(
          String(localized: "恢复摘要"),
          systemImage: "doc.plaintext"
        )
      }
      .workbenchProminentActionStyle()
      .disabled(isFetchingFullText)
      .help(String(localized: "恢复 RSS 原始摘要"))
      .accessibilityLabel("恢复 RSS 原始摘要")
      .accessibilityIdentifier("rss-reader-full-text-toggle")
    } else {
      Button {
        onToggleFullText()
      } label: {
        Label(
          String(localized: "提取全文"),
          systemImage: "sparkles"
        )
      }
      .buttonStyle(.bordered)
      .disabled(isFetchingFullText)
      .help(String(localized: "从原网站提取完整正文"))
      .accessibilityLabel("从原网站提取完整正文")
      .accessibilityIdentifier("rss-reader-full-text-toggle")
    }
  }

  @ViewBuilder
  private var readerBackButton: some View {
    if let onBack {
      Button("返回文章列表", systemImage: "chevron.left", action: onBack)
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .help("返回 RSS 文章列表")
        .accessibilityLabel("返回 RSS 文章列表")
    }
  }

  @ViewBuilder
  private var readerToolbarBusyIndicator: some View {
    if workflowIsBusy {
      ProgressView()
        .controlSize(.small)
        .accessibilityLabel("正在处理阅读内容")
    }
  }

  private func speechToggleButton(for article: RSSArticle) -> some View {
    let isCurrentArticle = speechController.currentArticleID == article.id
    let isActive = isCurrentArticle && speechController.isSpeaking
    let title: String
    let systemImage: String
    if !isActive {
      title = "听文章"
      systemImage = "speaker.wave.2"
    } else if speechController.isPaused {
      title = "继续朗读"
      systemImage = "play.fill"
    } else {
      title = "暂停朗读"
      systemImage = "pause.fill"
    }

    return Button {
      speechController.toggle(article: article)
    } label: {
      Label(title, systemImage: systemImage)
    }
    .buttonStyle(.bordered)
    .keyboardShortcut("l", modifiers: [.command, .option])
    .help(isActive ? (speechController.isPaused ? "继续朗读" : "暂停朗读") : "朗读正文")
    .accessibilityLabel(title)
    .accessibilityIdentifier("rss-reader-speech-toggle")
  }

  private var speechRateMenu: some View {
    Menu {
      Picker(
        "朗读速度",
        selection: Binding(
          get: { speechController.rateMultiplier },
          set: { speechController.setRateMultiplier($0) }
        )
      ) {
        ForEach(RSSArticleSpeechController.supportedRateMultipliers, id: \.self) { rate in
          Text("\(rate, specifier: "%.2f")x").tag(rate)
        }
      }
      if speechController.isSpeaking {
        Divider()
        Button("停止朗读", systemImage: "stop.fill", action: speechController.stop)
      }
    } label: {
      Label(
        "\(speechController.rateMultiplier, specifier: "%.2f")x",
        systemImage: "gauge.with.dots.needle.67percent"
      )
    }
    .menuStyle(.borderlessButton)
    .help("调整朗读速度，支持 1.0x 到 2.0x")
    .accessibilityLabel("朗读速度")
    .accessibilityValue("\(speechController.rateMultiplier, specifier: "%.2f")倍速")
    .accessibilityIdentifier("rss-reader-speech-rate")
  }

  private var translationControls: some View {
    RSSArticleTranslationControls(
      translation: translation,
      targetCode: $translationTargetCode,
      customLanguage: $translationCustomLanguage,
      automaticTranslation: $automaticTranslation,
      isTranslating: translationIsRunning,
      isShowingTranslation: showsTranslatedArticle,
      onTranslate: onTranslate,
      onToggleDisplay: { showsTranslatedArticle.toggle() },
      onClear: onClearTranslation,
      dataSharingConsent: dataSharingConsent,
      onOpenAISettings: onOpenAISettings
    )
  }

  private func starredButton(for article: RSSArticle) -> some View {
    Button(action: onToggleStarred) {
      Label(
        article.isStarred ? "移出稍后阅读" : "加入稍后阅读",
        systemImage: article.isStarred ? "star.fill" : "star"
      )
    }
    .buttonStyle(.bordered)
    .keyboardShortcut("s", modifiers: [.command, .control])
    .accessibilityLabel(article.isStarred ? "将文章移出稍后阅读" : "将文章加入稍后阅读")
    .accessibilityIdentifier("rss-reader-star")
  }

  private func readButton(for article: RSSArticle) -> some View {
    Button(action: onToggleRead) {
      Label(
        article.isRead ? "标为未读" : "标为已读",
        systemImage: article.isRead ? "circle" : "checkmark.circle"
      )
    }
    .buttonStyle(.bordered)
    .keyboardShortcut("u", modifiers: [.command, .control])
    .accessibilityLabel(article.isRead ? "将文章标为未读" : "将文章标为已读")
    .accessibilityIdentifier("rss-reader-read-toggle")
  }

  private var readingComfortControls: some View {
    Menu {
      readingComfortMenuContent
    } label: {
      Label("阅读舒适度", systemImage: "textformat.size")
    }
    .menuStyle(.borderlessButton)
    .help("调整 RSS 正文字号、行距和主题")
    .accessibilityLabel("阅读舒适度设置")
    .accessibilityIdentifier("rss-reader-comfort")
  }

  @ViewBuilder
  private var readingComfortMenuContent: some View {
    Section("正文字号") {
      Slider(
        value: $readingFontSize,
        in: RSSReadingComfortConfiguration.fontSizeRange,
        step: 1
      ) {
        Text("字号")
      } minimumValueLabel: {
        Text("小")
      } maximumValueLabel: {
        Text("大")
      }
      Text("当前 \(Int(readingFontSize)) pt")
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    Section("行距") {
      Slider(
        value: $readingLineSpacing,
        in: RSSReadingComfortConfiguration.lineSpacingRange,
        step: 0.05
      ) {
        Text("行距")
      } minimumValueLabel: {
        Text("紧")
      } maximumValueLabel: {
        Text("松")
      }
      Text("当前 \(readingLineSpacing, specifier: "%.2f")")
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    Picker("阅读主题", selection: $readingTheme) {
      ForEach(RSSReadingTheme.allCases) { theme in
        Label(theme.title, systemImage: theme.systemImage)
          .tag(theme)
      }
    }
  }

  private func annotationSummaryButton(for article: RSSArticle) -> some View {
    Button("查看标注", systemImage: "list.bullet.rectangle") {
      showsAnnotationSummary = true
    }
    .buttonStyle(.bordered)
    .help("查看当前文章的标签、高亮与批注")
    .accessibilityLabel("查看当前文章的标签、高亮与批注")
    .accessibilityIdentifier("rss-reader-annotation-summary")
  }

  @ViewBuilder
  private var annotationActionItems: some View {
    Button("高亮", systemImage: "highlighter", action: onBeginHighlight)
      .disabled(!hasSelectedText)
    Button("添加批注", systemImage: "note.text.badge.plus", action: onBeginNote)
      .disabled(!hasSelectedText)
    Divider()
    Button("编辑标签", systemImage: "tag", action: onEditTags)
      .keyboardShortcut("t", modifiers: [.command, .control])
  }

  private var hasSelectedText: Bool {
    !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private func readerOverflowMenu(
    for article: RSSArticle,
    speechArticle: RSSArticle
  ) -> some View {
    Menu {
      Button(
        article.isStarred ? "移出稍后阅读" : "加入稍后阅读",
        systemImage: article.isStarred ? "star.slash" : "star",
        action: onToggleStarred
      )
      Button(
        article.isRead ? "标为未读" : "标为已读",
        systemImage: article.isRead ? "circle" : "checkmark.circle",
        action: onToggleRead
      )
      if article.link != nil {
        Divider()
        Button(
          isShowingFullText ? String(localized: "恢复原始摘要") : String(localized: "提取原站全文"),
          systemImage: isShowingFullText ? "doc.plaintext" : "sparkles",
          action: onToggleFullText
        )
        .disabled(isFetchingFullText)
        if let automaticFullTextExtraction {
          Toggle(String(localized: "打开截断文章时自动提取全文"), isOn: automaticFullTextExtraction)
        }
        Button("在系统浏览器中打开原文", systemImage: "safari", action: onOpenOriginal)
      }

      Divider()
      speechToggleButton(for: speechArticle)
      speechRateMenu

      Divider()
      translationControls
      Button("查看标注", systemImage: "list.bullet.rectangle") {
        showsAnnotationSummary = true
      }
      .accessibilityLabel("查看当前文章的标签、高亮与批注")
      .accessibilityIdentifier("rss-reader-annotation-summary")

      Divider()
      Menu {
        readingComfortMenuContent
      } label: {
        Label("阅读舒适度", systemImage: "textformat.size")
      }
      Toggle("加载远程图片", isOn: $allowRemoteImages)

      Divider()
      annotationActionItems

      Divider()
      workflowActionItems(for: article)
    } label: {
      Label("更多阅读操作", systemImage: "ellipsis.circle")
    }
    .menuStyle(.button)
    .accessibilityLabel("更多阅读操作")
    .accessibilityIdentifier("rss-reader-more-actions")
  }

  private func workflowIntegrationMenu(for article: RSSArticle) -> some View {
    Menu {
      Section("保存到资料库") {
        workflowSaveActionItems(for: article)
      }
      Section("用于写作") {
        workflowWritingActionItems(for: article)
      }
    } label: {
      Label("导出/联动", systemImage: "arrow.up.forward.square")
    }
    .menuStyle(.button)
    .disabled(workflowIsBusy)
    .help("将当前文章保存到资料库，或联动到写作")
    .accessibilityLabel("导出与联动")
    .accessibilityHint("保存文章、摘录笔记、插入写作引用或新建灵感草稿")
    .accessibilityIdentifier("rss-reader-workflow-menu")
  }

  @ViewBuilder
  private func workflowSaveActionItems(for article: RSSArticle) -> some View {
    workflowActionButton(
      "保存文章摘要",
      systemImage: "doc.text",
      article: article,
      action: onSaveToKnowledge
    )
    workflowActionButton(
      "摘录并添加笔记",
      systemImage: "note.text.badge.plus",
      article: article,
      action: onAddExcerptNote
    )
  }

  @ViewBuilder
  private func workflowWritingActionItems(for article: RSSArticle) -> some View {
    workflowActionButton(
      "插入当前文章",
      systemImage: "arrow.down.doc",
      article: article,
      action: onInsertReference
    )
    workflowActionButton(
      "新建灵感草稿",
      systemImage: "square.and.pencil",
      article: article,
      action: onCreateInspirationDraft
    )
  }

  @ViewBuilder
  private func workflowActionItems(for article: RSSArticle) -> some View {
    workflowSaveActionItems(for: article)
    Divider()
    workflowWritingActionItems(for: article)
  }

  private func workflowActionButton(
    _ title: String,
    systemImage: String,
    article: RSSArticle,
    action: @escaping (RSSArticle) -> Void
  ) -> some View {
    Button {
      action(article)
    } label: {
      Label(title, systemImage: systemImage)
    }
    .disabled(workflowIsBusy)
    .accessibilityLabel(title)
  }

  @ViewBuilder
  private func originalArticleButton(for article: RSSArticle) -> some View {
    if let link = article.link {
      Button("打开原文", systemImage: "safari", action: onOpenOriginal)
        .buttonStyle(.bordered)
        .keyboardShortcut("o", modifiers: [.command, .control])
        .accessibilityLabel("在浏览器中打开原文")
        .help(link.absoluteString)
    }
  }

  private func annotationSummary(for article: RSSArticle) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        HStack {
          Label("标签、高亮与批注", systemImage: "highlighter")
            .font(.headline)
          Spacer()
          Button("关闭", systemImage: "xmark") {
            showsAnnotationSummary = false
          }
          .labelStyle(.iconOnly)
          .buttonStyle(.borderless)
          .accessibilityLabel("关闭标签与高亮")
        }
        articleTagSummary(for: article)
        Divider()
        if highlights.isEmpty {
          ContentUnavailableView(
            "暂无高亮与批注",
            systemImage: "highlighter",
            description: Text("在正文中选择文字后，可以添加高亮或批注。")
          )
        } else {
          highlightList
        }
      }
      .padding(WorkbenchSpacing.card)
    }
    .frame(
      minWidth: 380,
      idealWidth: 400,
      maxWidth: 440,
      minHeight: 180,
      idealHeight: 340,
      maxHeight: 480
    )
    .accessibilityElement(children: .contain)
    .accessibilityLabel("当前文章的标签、高亮与批注")
  }

  private func articleTagSummary(for article: RSSArticle) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Label("文章标签", systemImage: "tag")
          .font(.headline)
        Spacer()
        Button("编辑标签", action: onEditTags)
          .buttonStyle(.bordered)
          .keyboardShortcut("t", modifiers: [.command, .control])
      }
      if article.tags.isEmpty {
        Text("还没有标签")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        Text(article.tags.map { "#\($0)" }.joined(separator: "  "))
          .font(.callout)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
      }
    }
  }

  private var highlightList: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label("本篇高亮与批注", systemImage: "highlighter")
        .font(.headline)
      ForEach(highlights) { highlight in
        VStack(alignment: .leading, spacing: 5) {
          Text(highlight.text)
            .font(.callout.weight(.medium))
            .lineLimit(4)
          if !highlight.note.isEmpty {
            Text(highlight.note)
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(3)
          }
          if !highlight.tags.isEmpty {
            Text(highlight.tags.map { "#\($0)" }.joined(separator: "  "))
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          HStack {
            Spacer()
            Button("删除高亮") {
              onDeleteHighlight(highlight.id)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(WorkbenchTheme.risk)
            .accessibilityLabel("删除高亮：\(highlight.text)")
          }
        }
        .padding(WorkbenchSpacing.control)
        .background(
          WorkbenchBackgroundStyle.card,
          in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
        )
      }
    }
  }
}

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
          translationTargetCode: .constant("zh-Hans"),
          translationCustomLanguage: .constant(""),
          automaticTranslation: .constant(false),
          translationIsRunning: false,
          translationError: nil,
          dataSharingConsent: AIDataSharingConsentPresentation(
            providerName: "预览",
            destination: "本机",
            destinationState: .local,
            isGranted: true
          ),
          onTranslate: {},
          onClearTranslation: {},
          onOpenAISettings: {},
          workflowIsBusy: false,
          isTruncatedCandidate: false,
          isShowingFullText: false,
          isFetchingFullText: false,
          fullTextError: nil,
          automaticFullTextExtraction: nil,
          onToggleFullText: {}
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
