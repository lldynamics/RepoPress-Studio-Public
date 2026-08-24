import AppKit
import Foundation
import PublishingWorkbenchCore
import SwiftUI
import UniformTypeIdentifiers
import WebKit

#if canImport(Darwin)
  import Darwin
#endif
struct MarkdownPreviewWebView: NSViewRepresentable {
  let html: String
  let renderID: UUID?
  let assetResources: [MarkdownPreviewAssetResource]
  let scrollSyncUpdate: MarkdownScrollSyncUpdate?
  let scrollRestorationUpdate: MarkdownScrollSyncUpdate?
  let onScrollPositionChanged: (MarkdownScrollSyncPosition) -> Void
  let onSourceLocationSelected: (Int) -> Void

  @MainActor
  final class Coordinator: NSObject, WKNavigationDelegate {
    var lastLoadedRenderID: UUID?
    var latestScrollSyncUpdate: MarkdownScrollSyncUpdate?
    var latestScrollRestorationUpdate: MarkdownScrollSyncUpdate?
    private weak var webView: WKWebView?
    private var lastAppliedAnchorUpdateID: UUID?
    private var anchorEvaluationGeneration: UInt64 = 0
    private var isApplyingAnchorScroll = false
    private let onScrollPositionChanged: (MarkdownScrollSyncPosition) -> Void
    private lazy var scrollSyncBridge = MarkdownScrollViewSyncBridge(
      source: .preview,
      onPositionChanged: { [weak self] position in
        self?.resolveTopVisibleSourceLine(for: position)
      }
    )
    private let onSourceLocationSelected: (Int) -> Void
    let assetSchemeHandler = MarkdownPreviewAssetSchemeHandler()

    init(
      onScrollPositionChanged: @escaping (MarkdownScrollSyncPosition) -> Void,
      onSourceLocationSelected: @escaping (Int) -> Void
    ) {
      self.onScrollPositionChanged = onScrollPositionChanged
      self.onSourceLocationSelected = onSourceLocationSelected
      super.init()
    }

    func observeScrolling(in webView: WKWebView, allowDeferredRetry: Bool = true) {
      guard let scrollView = descendantScrollView(in: webView) else {
        guard allowDeferredRetry else { return }
        DispatchQueue.main.async { [weak self, weak webView] in
          guard let self, let webView else { return }
          self.observeScrolling(in: webView, allowDeferredRetry: false)
        }
        return
      }
      self.webView = webView
      scrollSyncBridge.observe(scrollView)
    }

    func applySynchronizedScroll(includingOwnSource: Bool = false) {
      guard let update = latestScrollSyncUpdate,
        includingOwnSource || update.source != .preview
      else {
        return
      }
      if let sourceLine = update.sourceLine,
        update.id != lastAppliedAnchorUpdateID,
        let webView
      {
        applyAnchor(sourceLine, update: update, in: webView)
        return
      }
      scrollSyncBridge.apply(
        update,
        includingOwnSource: includingOwnSource
      )
    }

    func applyRestoredScroll() {
      scrollSyncBridge.restore(latestScrollRestorationUpdate)
    }

    func invalidate() {
      anchorEvaluationGeneration &+= 1
      scrollSyncBridge.invalidate()
      webView = nil
    }

    private func resolveTopVisibleSourceLine(for position: MarkdownScrollSyncPosition) {
      guard !isApplyingAnchorScroll, let webView else { return }
      anchorEvaluationGeneration &+= 1
      let generation = anchorEvaluationGeneration
      let script = """
        (() => {
          const anchors = document.querySelectorAll('[data-source-line]');
          for (const anchor of anchors) {
            const rect = anchor.getBoundingClientRect();
            if (rect.bottom > 0 && rect.top < window.innerHeight) {
              return Number(anchor.dataset.sourceLine);
            }
          }
          return null;
        })()
        """
      webView.evaluateJavaScript(script) { [weak self] result, _ in
        guard let self, generation == self.anchorEvaluationGeneration else { return }
        let sourceLine = (result as? NSNumber)?.intValue
        self.onScrollPositionChanged(
          MarkdownScrollSyncPosition(sourceLine: sourceLine, progress: position.progress)
        )
      }
    }

    private func applyAnchor(
      _ sourceLine: Int,
      update: MarkdownScrollSyncUpdate,
      in webView: WKWebView
    ) {
      lastAppliedAnchorUpdateID = update.id
      isApplyingAnchorScroll = true
      anchorEvaluationGeneration &+= 1
      let script = """
        (() => {
          const requestedLine = \(sourceLine);
          var target = null;
          for (const anchor of document.querySelectorAll('[data-source-line]')) {
            const line = Number(anchor.dataset.sourceLine);
            if (!Number.isFinite(line) || line > requestedLine) { break; }
            target = anchor;
          }
          if (!target) { return false; }
          target.scrollIntoView({ block: 'start', inline: 'nearest', behavior: 'auto' });
          return true;
        })()
        """
      webView.evaluateJavaScript(script) { [weak self] result, _ in
        guard let self else { return }
        if (result as? NSNumber)?.boolValue != true {
          self.scrollSyncBridge.apply(update)
        }
        DispatchQueue.main.async { [weak self] in
          self?.isApplyingAnchorScroll = false
        }
      }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
      DispatchQueue.main.async { [weak self, weak webView] in
        guard let webView else { return }
        self?.observeScrolling(in: webView, allowDeferredRetry: false)
        self?.applyRestoredScroll()
        self?.applySynchronizedScroll(includingOwnSource: true)
      }
    }

    private func descendantScrollView(in view: NSView) -> NSScrollView? {
      if let scrollView = view as? NSScrollView {
        return scrollView
      }
      for subview in view.subviews {
        if let scrollView = descendantScrollView(in: subview) {
          return scrollView
        }
      }
      return nil
    }

    func webView(
      _ webView: WKWebView,
      decidePolicyFor navigationAction: WKNavigationAction,
      decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
      guard let url = navigationAction.request.url else {
        decisionHandler(.allow)
        return
      }
      if url.scheme == "about" {
        decisionHandler(.allow)
        return
      }
      if url.scheme == MarkdownPreviewAssetService.URLScheme {
        decisionHandler(.cancel)
        return
      }
      if let sourceLocation = MarkdownPreviewSourceLinkService.sourceLocation(from: url) {
        onSourceLocationSelected(sourceLocation)
        decisionHandler(.cancel)
        return
      }
      if navigationAction.navigationType == .linkActivated {
        _ = ExternalURLOpener.open(url)
      }
      decisionHandler(.cancel)
    }
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(
      onScrollPositionChanged: onScrollPositionChanged,
      onSourceLocationSelected: onSourceLocationSelected
    )
  }

  func makeNSView(context: Context) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.defaultWebpagePreferences.allowsContentJavaScript = false
    configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
    configuration.setURLSchemeHandler(
      context.coordinator.assetSchemeHandler,
      forURLScheme: MarkdownPreviewAssetService.URLScheme
    )
    let view = WKWebView(frame: .zero, configuration: configuration)
    view.navigationDelegate = context.coordinator
    view.setValue(false, forKey: "drawsBackground")
    context.coordinator.observeScrolling(in: view)
    return view
  }

  func updateNSView(_ nsView: WKWebView, context: Context) {
    context.coordinator.latestScrollSyncUpdate = scrollSyncUpdate
    context.coordinator.latestScrollRestorationUpdate = scrollRestorationUpdate
    guard let renderID, context.coordinator.lastLoadedRenderID != renderID else {
      context.coordinator.applySynchronizedScroll()
      context.coordinator.applyRestoredScroll()
      return
    }
    context.coordinator.assetSchemeHandler.update(resources: assetResources)
    context.coordinator.lastLoadedRenderID = renderID
    nsView.loadHTMLString(html, baseURL: nil)
  }

  static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
    nsView.navigationDelegate = nil
    coordinator.invalidate()
  }
}
