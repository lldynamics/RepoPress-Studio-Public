import AppKit
import PublishingWorkbenchCore
import SwiftUI
import WebKit

enum LocalSitePreviewNavigationPolicy {
  static func isAllowedLoopbackURL(_ url: URL, matching previewURL: URL) -> Bool {
    guard let candidate = URLComponents(url: url, resolvingAgainstBaseURL: false),
          candidate.scheme == "http",
          candidate.user == nil,
          candidate.password == nil,
          let host = candidate.host?.lowercased(),
          ["127.0.0.1", "localhost", "::1"].contains(host),
          let expectedPort = previewURL.port,
          (candidate.port ?? 80) == expectedPort else {
      return false
    }
    return true
  }
}

struct LocalSitePreviewWebView: NSViewRepresentable {
  let url: URL
  let reloadToken: UInt64
  let onNavigationError: (String) -> Void

  @MainActor
  final class Coordinator: NSObject, WKNavigationDelegate {
    var lastLoadedURL: URL?
    var lastReloadToken: UInt64?
    var previewURL: URL
    let onNavigationError: (String) -> Void

    init(previewURL: URL, onNavigationError: @escaping (String) -> Void) {
      self.previewURL = previewURL
      self.onNavigationError = onNavigationError
      super.init()
    }

    func webView(
      _ webView: WKWebView,
      decidePolicyFor navigationAction: WKNavigationAction,
      decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
      guard let destination = navigationAction.request.url else {
        onNavigationError("预览页面返回了无效链接。")
        decisionHandler(.cancel)
        return
      }
      if destination.scheme == "about" {
        decisionHandler(.allow)
        return
      }
      if LocalSitePreviewNavigationPolicy.isAllowedLoopbackURL(
        destination,
        matching: previewURL
      ) {
        decisionHandler(.allow)
        return
      }

      if navigationAction.navigationType == .linkActivated {
        _ = ExternalURLOpener.open(destination) { [weak self] message in
          self?.onNavigationError(message)
        }
      } else {
        onNavigationError("预览页面尝试跳转到非本地地址，已阻止该跳转。")
      }
      decisionHandler(.cancel)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
      onNavigationError(error.localizedDescription)
    }

    func webView(
      _ webView: WKWebView,
      didFailProvisionalNavigation navigation: WKNavigation!,
      withError error: Error
    ) {
      onNavigationError(error.localizedDescription)
    }
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(previewURL: url, onNavigationError: onNavigationError)
  }

  func makeNSView(context: Context) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.defaultWebpagePreferences.allowsContentJavaScript = true
    configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
    let scrollbarScript = WKUserScript(
      source: ThinRedScrollbarWebStyle.injectionSource,
      injectionTime: .atDocumentEnd,
      forMainFrameOnly: true
    )
    configuration.userContentController.addUserScript(scrollbarScript)
    let webView = WKWebView(frame: .zero, configuration: configuration)
    webView.navigationDelegate = context.coordinator
    webView.allowsMagnification = true
    webView.setValue(false, forKey: "drawsBackground")
    return webView
  }

  func updateNSView(_ nsView: WKWebView, context: Context) {
    context.coordinator.previewURL = url
    if context.coordinator.lastLoadedURL != url {
      context.coordinator.lastLoadedURL = url
      context.coordinator.lastReloadToken = reloadToken
      nsView.load(URLRequest(url: url))
      return
    }
    guard context.coordinator.lastReloadToken != reloadToken else { return }
    context.coordinator.lastReloadToken = reloadToken
    nsView.reload()
  }
}
