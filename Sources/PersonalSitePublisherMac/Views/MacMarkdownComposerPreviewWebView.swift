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
  let onScrollProgressChanged: (Double) -> Void
  let onSourceLocationSelected: (Int) -> Void

  @MainActor
  final class Coordinator: NSObject, WKNavigationDelegate {
    var lastLoadedRenderID: UUID?
    var latestScrollSyncUpdate: MarkdownScrollSyncUpdate?
    var latestScrollRestorationUpdate: MarkdownScrollSyncUpdate?
    private let scrollSyncBridge: MarkdownScrollViewSyncBridge
    private let onSourceLocationSelected: (Int) -> Void
    let assetSchemeHandler = MarkdownPreviewAssetSchemeHandler()

    init(
      onScrollProgressChanged: @escaping (Double) -> Void,
      onSourceLocationSelected: @escaping (Int) -> Void
    ) {
      scrollSyncBridge = MarkdownScrollViewSyncBridge(
        source: .preview,
        onProgressChanged: onScrollProgressChanged
      )
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
      scrollSyncBridge.observe(scrollView)
    }

    func applySynchronizedScroll(includingOwnSource: Bool = false) {
      scrollSyncBridge.apply(
        latestScrollSyncUpdate,
        includingOwnSource: includingOwnSource
      )
    }

    func applyRestoredScroll() {
      scrollSyncBridge.restore(latestScrollRestorationUpdate)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
      DispatchQueue.main.async { [weak self, weak webView] in
        guard let webView else { return }
        self?.observeScrolling(in: webView, allowDeferredRetry: false)
        self?.applySynchronizedScroll(includingOwnSource: true)
        self?.applyRestoredScroll()
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
      onScrollProgressChanged: onScrollProgressChanged,
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
}
