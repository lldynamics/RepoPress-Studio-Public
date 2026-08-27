import AppKit
import PublishingWorkbenchCore
import SwiftUI
import WebKit

enum LocalSitePreviewNavigationPolicy {
  static func isAllowedNavigationURL(_ url: URL, matching previewURL: URL?) -> Bool {
    if url.scheme?.lowercased() == "about" {
      return true
    }
    guard let previewURL else { return false }
    return isAllowedLoopbackURL(url, matching: previewURL)
  }

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

  struct TeardownState: Equatable, Sendable {
    fileprivate(set) var didStopLoading = false
    fileprivate(set) var didNavigateToBlank = false
    fileprivate(set) var didRemoveUserScripts = false
    fileprivate(set) var didDetachNavigationDelegate = false
    fileprivate(set) var didResetCoordinator = false

    var isComplete: Bool {
      didStopLoading
        && didNavigateToBlank
        && didRemoveUserScripts
        && didDetachNavigationDelegate
        && didResetCoordinator
    }
  }

  enum Teardown {
    static let blankURL = URL(string: "about:blank")!

    @discardableResult
    static func perform(
      stopLoading: () -> Void,
      navigateToBlank: () -> Void,
      removeUserScripts: () -> Void,
      detachNavigationDelegate: () -> Void,
      resetCoordinator: () -> Void
    ) -> TeardownState {
      var state = TeardownState()

      stopLoading()
      state.didStopLoading = true
      navigateToBlank()
      state.didNavigateToBlank = true
      removeUserScripts()
      state.didRemoveUserScripts = true
      detachNavigationDelegate()
      state.didDetachNavigationDelegate = true
      resetCoordinator()
      state.didResetCoordinator = true
      return state
    }

    @MainActor
    @discardableResult
    static func perform(
      on webView: WKWebView,
      coordinator: Coordinator
    ) -> TeardownState {
      // Keep the blank request ahead of delegate removal so the existing
      // policy still treats cleanup as an allowed local transition.
      return perform(
        stopLoading: {
          webView.stopLoading()
        },
        navigateToBlank: {
          webView.load(URLRequest(url: blankURL))
        },
        removeUserScripts: {
          webView.configuration.userContentController.removeAllUserScripts()
        },
        detachNavigationDelegate: {
          webView.navigationDelegate = nil
        },
        resetCoordinator: {
          coordinator.resetForTeardown()
        }
      )
    }
  }

  @MainActor
  final class Coordinator: NSObject, WKNavigationDelegate {
    var lastLoadedURL: URL?
    var lastReloadToken: UInt64?
    var previewURL: URL?
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
      if LocalSitePreviewNavigationPolicy.isAllowedNavigationURL(
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

    func resetForTeardown() {
      lastLoadedURL = nil
      lastReloadToken = nil
      previewURL = nil
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

  @MainActor
  static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
    _ = Teardown.perform(on: nsView, coordinator: coordinator)
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
