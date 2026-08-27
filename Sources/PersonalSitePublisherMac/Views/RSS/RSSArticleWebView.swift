import AppKit
import CryptoKit
import Foundation
import PublishingWorkbenchCore
import SwiftUI
import WebKit

struct RSSArticleWebView: NSViewRepresentable {
  let article: RSSArticle
  let feedTitle: String?
  let readingMinutes: Int
  let allowRemoteImages: Bool
  let highlights: [RSSArticleHighlight]
  let mediaAssets: [RSSMediaAsset]
  let mediaCacheDirectoryURL: URL?
  let fontSize: Double
  let lineSpacing: Double
  let theme: RSSReadingTheme
  let initialReadingProgress: Double
  let renderRevision: String
  let speechHighlight: RSSArticleSpeechHighlight?
  let onSelectionChanged: (String) -> Void
  let onReadingProgress: (Double) -> Void
  let onNavigationError: (String) -> Void

  init(
    article: RSSArticle,
    feedTitle: String? = nil,
    readingMinutes: Int = 1,
    allowRemoteImages: Bool,
    highlights: [RSSArticleHighlight],
    mediaAssets: [RSSMediaAsset] = [],
    mediaCacheDirectoryURL: URL? = nil,
    fontSize: Double = RSSReadingComfortConfiguration.defaultFontSize,
    lineSpacing: Double = RSSReadingComfortConfiguration.defaultLineSpacing,
    theme: RSSReadingTheme = .system,
    initialReadingProgress: Double = 0,
    renderRevision: String,
    speechHighlight: RSSArticleSpeechHighlight? = nil,
    onSelectionChanged: @escaping (String) -> Void,
    onReadingProgress: @escaping (Double) -> Void = { _ in },
    onNavigationError: @escaping (String) -> Void
  ) {
    self.article = article
    self.feedTitle = feedTitle
    self.readingMinutes = readingMinutes
    self.allowRemoteImages = allowRemoteImages
    self.highlights = highlights
    self.mediaAssets = mediaAssets
    self.mediaCacheDirectoryURL = mediaCacheDirectoryURL
    self.fontSize = fontSize
    self.lineSpacing = lineSpacing
    self.theme = theme
    self.initialReadingProgress = initialReadingProgress
    self.renderRevision = renderRevision
    self.speechHighlight = speechHighlight
    self.onSelectionChanged = onSelectionChanged
    self.onReadingProgress = onReadingProgress
    self.onNavigationError = onNavigationError
  }

  @MainActor
  final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    var lastRenderToken: String?
    private var renderGeneration: UInt64 = 0
    private var renderTask: Task<Void, Never>?
    private var pendingNavigation: WKNavigation?
    private var callbacksEnabled = false
    var lastAppliedSpeechHighlight: RSSArticleSpeechHighlight?
    var pendingHighlights: [RSSArticleHighlight] = []
    var pendingSpeechHighlight: RSSArticleSpeechHighlight?
    var pendingReadingProgress = 0.0
    var pendingFontSize = RSSReadingComfortConfiguration.defaultFontSize
    var pendingLineSpacing = RSSReadingComfortConfiguration.defaultLineSpacing
    var pendingTheme = RSSReadingTheme.system
    var onSelectionChanged: (String) -> Void
    var onReadingProgress: (Double) -> Void
    var onNavigationError: (String) -> Void

    init(
      onSelectionChanged: @escaping (String) -> Void,
      onReadingProgress: @escaping (Double) -> Void,
      onNavigationError: @escaping (String) -> Void
    ) {
      self.onSelectionChanged = onSelectionChanged
      self.onReadingProgress = onReadingProgress
      self.onNavigationError = onNavigationError
      super.init()
    }

    func updateCallbacks(
      onSelectionChanged: @escaping (String) -> Void,
      onReadingProgress: @escaping (Double) -> Void,
      onNavigationError: @escaping (String) -> Void
    ) {
      self.onSelectionChanged = onSelectionChanged
      self.onReadingProgress = onReadingProgress
      self.onNavigationError = onNavigationError
    }

    func scheduleRender(
      article: RSSArticle,
      feedTitle: String?,
      readingMinutes: Int,
      allowRemoteImages: Bool,
      mediaAssets: [RSSMediaAsset],
      mediaCacheDirectoryURL: URL?,
      fontSize: Double,
      lineSpacing: Double,
      theme: RSSReadingTheme,
      initialReadingProgress: Double,
      token: String,
      in webView: WKWebView
    ) {
      renderGeneration &+= 1
      let generation = renderGeneration
      renderTask?.cancel()
      callbacksEnabled = false
      pendingNavigation = nil

      let detachedTask = Task.detached(priority: .userInitiated) {
        RSSArticleHTMLRenderer.render(
          article: article,
          feedTitle: feedTitle,
          readingMinutes: readingMinutes,
          allowRemoteImages: allowRemoteImages,
          mediaAssets: mediaAssets,
          mediaCacheDirectoryURL: mediaCacheDirectoryURL,
          fontSize: fontSize,
          lineSpacing: lineSpacing,
          theme: theme,
          initialReadingProgress: initialReadingProgress
        )
      }

      renderTask = Task { @MainActor [weak self, weak webView] in
        let html = await withTaskCancellationHandler(
          operation: { await detachedTask.value },
          onCancel: { detachedTask.cancel() }
        )
        guard !Task.isCancelled,
          let self,
          let webView,
          self.renderGeneration == generation,
          self.lastRenderToken == token
        else { return }
        self.renderTask = nil
        self.pendingNavigation = webView.loadHTMLString(
          html,
          // The renderer has already resolved permitted relative links and
          // image URLs. Keeping this document on about:blank prevents the
          // navigation delegate from mistaking it for an external page.
          baseURL: nil
        )
      }
    }

    func userContentController(
      _ userContentController: WKUserContentController,
      didReceive message: WKScriptMessage
    ) {
      guard callbacksEnabled else { return }
      if message.name == "rssSelection", let value = message.body as? String {
        onSelectionChanged(value.trimmingCharacters(in: .whitespacesAndNewlines))
      } else if message.name == "rssProgress", let value = message.body as? NSNumber {
        onReadingProgress(min(max(value.doubleValue, 0), 1))
      }
    }

    func webView(
      _ webView: WKWebView,
      decidePolicyFor navigationAction: WKNavigationAction,
      decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
      guard let destination = navigationAction.request.url else {
        decisionHandler(.cancel)
        return
      }
      if destination.scheme == "about" {
        decisionHandler(.allow)
        return
      }
      guard navigationAction.navigationType == .linkActivated else {
        decisionHandler(.cancel)
        return
      }
      if destination.scheme?.lowercased() == "mailto" {
        if !NSWorkspace.shared.open(destination) {
          onNavigationError("无法打开邮件链接。")
        }
      } else {
        _ = ExternalURLOpener.open(destination, report: onNavigationError)
      }
      decisionHandler(.cancel)
    }

    func webView(
      _ webView: WKWebView,
      didFinish navigation: WKNavigation!
    ) {
      guard let pendingNavigation, navigation === pendingNavigation else { return }
      callbacksEnabled = true
      hideHorizontalScrollers(in: webView)
      applyReadingPreferences(to: webView)
      applyHighlights(to: webView)
      let progress = min(max(pendingReadingProgress, 0), 1)
      webView.evaluateJavaScript(
        "window.rssApplyReadingProgress && window.rssApplyReadingProgress(\(progress));"
      )
      applySpeechHighlight(to: webView)
    }

    func hideHorizontalScrollers(in webView: WKWebView, allowDeferredRetry: Bool = true) {
      let scrollViews = descendantScrollViews(in: webView)
      for scrollView in scrollViews {
        scrollView.hasHorizontalScroller = false
        scrollView.horizontalScrollElasticity = .none
      }

      guard allowDeferredRetry else { return }
      for delay in [0.0, 0.08, 0.25] {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak webView] in
          guard let self, let webView else { return }
          self.hideHorizontalScrollers(in: webView, allowDeferredRetry: false)
        }
      }
    }

    private func descendantScrollViews(in view: NSView) -> [NSScrollView] {
      var scrollViews: [NSScrollView] = []
      if let scrollView = view as? NSScrollView {
        scrollViews.append(scrollView)
      }
      for subview in view.subviews {
        scrollViews.append(contentsOf: descendantScrollViews(in: subview))
      }
      return scrollViews
    }

    func webView(
      _ webView: WKWebView,
      didFailProvisionalNavigation navigation: WKNavigation!,
      withError error: Error
    ) {
      guard let pendingNavigation, navigation === pendingNavigation else { return }
      onNavigationError(error.localizedDescription)
    }

    func applyReadingPreferences(to webView: WKWebView) {
      let script = """
        window.rssApplyReadingPreferences && window.rssApplyReadingPreferences(
          \(pendingFontSize),
          \(pendingLineSpacing),
          \(json(pendingTheme.cssBackground)),
          \(json(pendingTheme.cssForeground)),
          \(json(pendingTheme.cssSecondaryForeground)),
          \(json(pendingTheme.cssLink)),
          \(json(pendingTheme.cssColorScheme))
        );
        """
      webView.evaluateJavaScript(script)
    }

    func applyHighlights(to webView: WKWebView) {
      for highlight in pendingHighlights.sorted(by: Self.highlightRestoreOrder) {
        let text = json(highlight.text)
        let id = json(highlight.id.uuidString)
        webView.evaluateJavaScript("window.rssApplyHighlight(\(text), \(id));")
      }
    }

    func applySpeechHighlight(to webView: WKWebView) {
      let text = json(pendingSpeechHighlight?.text ?? "")
      webView.evaluateJavaScript(
        "window.rssApplySpeechHighlight && window.rssApplySpeechHighlight(\(text));"
      )
      lastAppliedSpeechHighlight = pendingSpeechHighlight
    }

    private static func highlightRestoreOrder(
      _ lhs: RSSArticleHighlight,
      _ rhs: RSSArticleHighlight
    ) -> Bool {
      if lhs.createdAt != rhs.createdAt {
        return lhs.createdAt < rhs.createdAt
      }
      return lhs.id.uuidString < rhs.id.uuidString
    }

    private func json(_ value: String) -> String {
      guard
        let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]),
        let string = String(data: data, encoding: .utf8)
      else { return "\"\"" }
      return string
    }
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(
      onSelectionChanged: onSelectionChanged,
      onReadingProgress: onReadingProgress,
      onNavigationError: onNavigationError
    )
  }

  func makeNSView(context: Context) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.defaultWebpagePreferences.allowsContentJavaScript = true
    configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
    let selectionScript = WKUserScript(
      source: """
        (() => {
          const report = () => {
            const value = (window.getSelection()?.toString() || '').trim();
            window.webkit.messageHandlers.rssSelection.postMessage(value);
          };
          document.addEventListener('selectionchange', report);
          document.addEventListener('mouseup', report);
          window.rssApplyHighlight = (text, id) => {
            if (!text || !id) return;
            const root = document.getElementById('rss-article-container') || document.body;
            if ([...root.querySelectorAll('mark.rss-highlight')].some(mark => mark.dataset.highlightId === id)) {
              return;
            }
            const normalizedNeedle = String(text).replace(/\\s+/g, ' ').trim();
            if (!normalizedNeedle) return;

            const blockSelector = 'address,article,aside,blockquote,div,dl,fieldset,figcaption,figure,footer,form,h1,h2,h3,h4,h5,h6,header,li,main,nav,ol,p,pre,section,table,td,th,ul';
            const blockElement = node => node.parentElement?.closest(blockSelector) || null;
            const characters = [];
            const positions = [];
            let previousBlock = null;
            const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
            while (walker.nextNode()) {
              const node = walker.currentNode;
              if (!node.nodeValue || node.parentElement?.closest('mark.rss-highlight,script,style,noscript')) {
                continue;
              }
              const currentBlock = blockElement(node);
              if (
                previousBlock &&
                currentBlock &&
                previousBlock !== currentBlock &&
                characters.length > 0 &&
                characters[characters.length - 1] !== ' '
              ) {
                characters.push(' ');
                positions.push({ node, offset: 0 });
              }
              for (let offset = 0; offset < node.nodeValue.length; offset += 1) {
                const character = node.nodeValue[offset];
                if (/\\s/.test(character)) {
                  if (characters.length > 0 && characters[characters.length - 1] !== ' ') {
                    characters.push(' ');
                    positions.push({ node, offset });
                  }
                } else {
                  characters.push(character);
                  positions.push({ node, offset });
                }
              }
              previousBlock = currentBlock;
            }
            while (characters[0] === ' ') {
              characters.shift();
              positions.shift();
            }
            while (characters[characters.length - 1] === ' ') {
              characters.pop();
              positions.pop();
            }

            const normalizedText = characters.join('');
            const matchStart = normalizedText.indexOf(normalizedNeedle);
            if (matchStart < 0) return;
            const startPosition = positions[matchStart];
            const endPosition = positions[matchStart + normalizedNeedle.length - 1];
            if (!startPosition || !endPosition) return;

            const range = document.createRange();
            range.setStart(startPosition.node, startPosition.offset);
            range.setEnd(endPosition.node, endPosition.offset + 1);
            const mark = document.createElement('mark');
            mark.className = 'rss-highlight';
            mark.dataset.highlightId = id;
            mark.appendChild(range.extractContents());
            range.insertNode(mark);
          };
        })();
        """,
      injectionTime: .atDocumentEnd,
      forMainFrameOnly: true
    )
    let speechHighlightScript = WKUserScript(
      source: """
        (() => {
          const speechBlockSelector = 'address,article,aside,blockquote,div,dl,fieldset,figcaption,figure,footer,form,h1,h2,h3,h4,h5,h6,header,li,main,nav,ol,p,pre,section,table,td,th,ul';
          const removeSpeechMarks = () => {
            document.querySelectorAll('mark.rss-speech-highlight').forEach(mark => {
              const parent = mark.parentNode;
              if (!parent) return;
              while (mark.firstChild) parent.insertBefore(mark.firstChild, mark);
              parent.removeChild(mark);
              parent.normalize();
            });
          };
          const normalizedWhitespace = value => String(value || '').replace(/\\s+/g, ' ');
          window.rssApplySpeechHighlight = text => {
            removeSpeechMarks();
            const normalizedNeedle = normalizedWhitespace(text).trim();
            if (!normalizedNeedle) return;

            const root = document.getElementById('rss-article-body') || document.body;
            const characters = [];
            const positions = [];
            let previousBlock = null;
            const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
            while (walker.nextNode()) {
              const node = walker.currentNode;
              if (!node.nodeValue || node.parentElement?.closest('script,style,noscript')) {
                continue;
              }
              const currentBlock = node.parentElement?.closest(speechBlockSelector) || null;
              if (
                previousBlock &&
                currentBlock &&
                previousBlock !== currentBlock &&
                characters.length > 0 &&
                characters[characters.length - 1] !== ' '
              ) {
                characters.push(' ');
                positions.push({ node, offset: 0 });
              }
              for (let offset = 0; offset < node.nodeValue.length; offset += 1) {
                const character = node.nodeValue[offset];
                if (/\\s/.test(character)) {
                  if (characters.length > 0 && characters[characters.length - 1] !== ' ') {
                    characters.push(' ');
                    positions.push({ node, offset });
                  }
                } else {
                  characters.push(character);
                  positions.push({ node, offset });
                }
              }
              previousBlock = currentBlock;
            }
            while (characters[0] === ' ') {
              characters.shift();
              positions.shift();
            }
            while (characters[characters.length - 1] === ' ') {
              characters.pop();
              positions.pop();
            }

            const normalizedText = characters.join('');
            const matchStart = normalizedText.indexOf(normalizedNeedle);
            if (matchStart < 0) return;
            const startPosition = positions[matchStart];
            const endPosition = positions[matchStart + normalizedNeedle.length - 1];
            if (!startPosition || !endPosition) return;

            const range = document.createRange();
            range.setStart(startPosition.node, startPosition.offset);
            range.setEnd(endPosition.node, endPosition.offset + 1);
            const mark = document.createElement('mark');
            mark.className = 'rss-speech-highlight';
            mark.appendChild(range.extractContents());
            range.insertNode(mark);
            mark.scrollIntoView({ behavior: 'smooth', block: 'center', inline: 'nearest' });
          };
        })();
        """,
      injectionTime: .atDocumentEnd,
      forMainFrameOnly: true
    )
    let readingPreferencesScript = WKUserScript(
      source: """
        (() => {
          window.rssApplyReadingPreferences = (
            fontSize,
            lineSpacing,
            background,
            foreground,
            secondaryForeground,
            link,
            colorScheme
          ) => {
            const root = document.documentElement;
            const normalizedFontSize = Math.min(24, Math.max(13, Number(fontSize) || 17));
            const normalizedLineSpacing = Math.min(2.10, Math.max(1.35, Number(lineSpacing) || 1.65));
            root.style.setProperty('--rss-font-size', String(normalizedFontSize) + 'px');
            root.style.setProperty('--rss-line-spacing', String(normalizedLineSpacing));
            root.style.setProperty('--rss-background', String(background || 'transparent'));
            root.style.setProperty('--rss-foreground', String(foreground || '-apple-system-label'));
            root.style.setProperty('--rss-secondary-foreground', String(secondaryForeground || '-apple-system-secondary-label'));
            root.style.setProperty('--rss-link', String(link || '-apple-system-link'));
            root.style.colorScheme = String(colorScheme || 'light dark');
          };
        })();
        """,
      injectionTime: .atDocumentEnd,
      forMainFrameOnly: true
    )
    let progressScript = WKUserScript(
      source: """
        (() => {
          const report = () => {
            const documentHeight = Math.max(document.documentElement.scrollHeight, document.body?.scrollHeight || 0);
            const maximum = Math.max(0, documentHeight - window.innerHeight);
            const progress = maximum > 0 ? window.scrollY / maximum : 0;
            window.webkit.messageHandlers.rssProgress.postMessage(progress);
          };
          window.rssApplyReadingProgress = (value) => {
            const documentHeight = Math.max(document.documentElement.scrollHeight, document.body?.scrollHeight || 0);
            const maximum = Math.max(0, documentHeight - window.innerHeight);
            window.scrollTo(0, maximum * Math.min(1, Math.max(0, Number(value) || 0)));
            report();
          };
          window.addEventListener('scroll', report, { passive: true });
          window.addEventListener('resize', report);
          report();
        })();
        """,
      injectionTime: .atDocumentEnd,
      forMainFrameOnly: true
    )
    configuration.userContentController.addUserScript(selectionScript)
    configuration.userContentController.addUserScript(speechHighlightScript)
    configuration.userContentController.addUserScript(readingPreferencesScript)
    configuration.userContentController.addUserScript(progressScript)
    configuration.userContentController.add(context.coordinator, name: "rssSelection")
    configuration.userContentController.add(context.coordinator, name: "rssProgress")
    let webView = WKWebView(frame: .zero, configuration: configuration)
    webView.navigationDelegate = context.coordinator
    webView.allowsMagnification = true
    context.coordinator.hideHorizontalScrollers(in: webView)
    webView.setValue(true, forKey: "drawsBackground")
    return webView
  }

  func updateNSView(_ nsView: WKWebView, context: Context) {
    let highlightsToken = highlights.map {
      "\($0.id.uuidString):\($0.updatedAt.timeIntervalSince1970)"
    }.joined(separator: ",")
    let mediaToken = mediaAssets.map(\.id).joined(separator: ",")
    context.coordinator.updateCallbacks(
      onSelectionChanged: onSelectionChanged,
      onReadingProgress: onReadingProgress,
      onNavigationError: onNavigationError
    )
    context.coordinator.pendingHighlights = highlights
    let speechHighlightChanged = context.coordinator.lastAppliedSpeechHighlight != speechHighlight
    context.coordinator.pendingSpeechHighlight = speechHighlight
    context.coordinator.pendingReadingProgress = initialReadingProgress
    context.coordinator.pendingFontSize = fontSize
    context.coordinator.pendingLineSpacing = lineSpacing
    context.coordinator.pendingTheme = theme
    // Reading progress is applied by the page's scroll handler. Including it
    // in this identity would rebuild/sanitize the entire document for every
    // 1% scroll update, which is both unnecessary and visibly janky.
    let token =
      "\(article.id)|\(renderRevision)|\(allowRemoteImages)|\(highlightsToken)|\(mediaToken)"
    guard context.coordinator.lastRenderToken != token else {
      context.coordinator.applyReadingPreferences(to: nsView)
      if speechHighlightChanged {
        context.coordinator.applySpeechHighlight(to: nsView)
      }
      return
    }
    context.coordinator.lastRenderToken = token
    context.coordinator.lastAppliedSpeechHighlight = nil
    context.coordinator.scheduleRender(
      article: article,
      feedTitle: feedTitle,
      readingMinutes: readingMinutes,
      allowRemoteImages: allowRemoteImages,
      mediaAssets: mediaAssets,
      mediaCacheDirectoryURL: mediaCacheDirectoryURL,
      fontSize: fontSize,
      lineSpacing: lineSpacing,
      theme: theme,
      initialReadingProgress: initialReadingProgress,
      token: token,
      in: nsView
    )
  }
}
