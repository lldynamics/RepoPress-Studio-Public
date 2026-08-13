import SwiftUI
import WebKit

struct MermaidDiagramRenderWebView: NSViewRepresentable {
  let mermaidCode: String
  @Environment(\.colorScheme) private var colorScheme

  @MainActor
  final class Coordinator: NSObject, WKNavigationDelegate {
    var lastRenderedCode: String?
    var lastRenderedIsDark: Bool?

    private var pendingThemeIsDark: Bool?
    private var pendingNavigation: WKNavigation?
    private var isDocumentReady = false

    func beginRendering(html: String, in webView: WKWebView) {
      isDocumentReady = false
      pendingThemeIsDark = nil
      pendingNavigation = webView.loadHTMLString(html, baseURL: nil)
    }

    func applyThemeIfReady(isDark: Bool, to webView: WKWebView) {
      guard isDocumentReady else {
        pendingThemeIsDark = isDark
        return
      }
      applyTheme(isDark: isDark, to: webView)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
      guard let pendingNavigation, navigation === pendingNavigation else { return }
      self.pendingNavigation = nil
      isDocumentReady = true

      guard let pendingThemeIsDark else { return }
      self.pendingThemeIsDark = nil
      applyTheme(isDark: pendingThemeIsDark, to: webView)
    }

    private func applyTheme(isDark: Bool, to webView: WKWebView) {
      let theme = MermaidThemeValues.name(isDark: isDark)
      let foreground = MermaidThemeValues.foreground(isDark: isDark)
      let fallbackBackground = MermaidThemeValues.fallbackBackground(isDark: isDark)
      webView.evaluateJavaScript(
        """
        (() => {
          const root = document.documentElement;
          root.dataset.mermaidTheme = '\(theme)';
          root.style.setProperty('--mermaid-foreground', '\(foreground)');
          root.style.setProperty('--mermaid-fallback-background', '\(fallbackBackground)');
          if (typeof window.renderMermaidTheme === 'function') {
            window.renderMermaidTheme('\(theme)');
          }
        })();
        """
      )
    }
  }

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  func makeNSView(context: Context) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    let webView = WKWebView(frame: .zero, configuration: configuration)
    webView.navigationDelegate = context.coordinator
    webView.setValue(false, forKey: "drawsBackground")
    return webView
  }

  func updateNSView(_ nsView: WKWebView, context: Context) {
    let isDark = colorScheme == .dark
    let coordinator = context.coordinator

    guard coordinator.lastRenderedCode == mermaidCode else {
      coordinator.lastRenderedCode = mermaidCode
      coordinator.lastRenderedIsDark = isDark
      coordinator.beginRendering(
        html: htmlContent(for: mermaidCode, isDark: isDark),
        in: nsView
      )
      return
    }

    guard coordinator.lastRenderedIsDark != isDark else { return }
    coordinator.lastRenderedIsDark = isDark
    coordinator.applyThemeIfReady(isDark: isDark, to: nsView)
  }

  private func htmlContent(for code: String, isDark: Bool) -> String {
    let theme = isDark ? "dark" : "default"
    let escapedCode = htmlEscaped(code)
    let fallbackTitle = htmlEscaped(String(localized: "Mermaid 本地渲染脚本不可用"))
    let fallbackMessage = htmlEscaped(
      String(localized: "已显示 Mermaid 源码文本。请重新安装包含本地脚本的应用后重试。")
    )

    let mermaidScriptTag: String
    let bodyContent: String
    if let localURL = Bundle.main.url(forResource: "mermaid.min", withExtension: "js"),
       localURL.isFileURL {
      mermaidScriptTag = "<script src=\"\(localURL.absoluteString)\"></script>"
      bodyContent = """
      <div class="mermaid">
      \(escapedCode)
      </div>
      <template id="mermaid-fallback-template">
        <strong>\(fallbackTitle)</strong>
        <p>\(fallbackMessage)</p>
      </template>
      <script>
        function renderMermaidFallback() {
          const container = document.querySelector('.mermaid');
          const template = document.querySelector('#mermaid-fallback-template');
          if (!container || !template) { return; }
          const source = container.dataset.mermaidSource || container.textContent || '';
          container.classList.add('fallback-container');
          container.replaceChildren(template.content.cloneNode(true));
          const sourceBlock = document.createElement('pre');
          sourceBlock.className = 'fallback';
          sourceBlock.textContent = source;
          container.appendChild(sourceBlock);
        }

        function rememberMermaidSource() {
          const container = document.querySelector('.mermaid');
          if (container && !container.dataset.mermaidSource) {
            container.dataset.mermaidSource = container.textContent || '';
          }
        }

        window.renderMermaidTheme = function(theme) {
          const container = document.querySelector('.mermaid');
          if (!container || typeof mermaid === 'undefined') { return; }
          rememberMermaidSource();
          const source = container.dataset.mermaidSource || '';
          container.classList.remove('fallback-container');
          container.removeAttribute('data-processed');
          container.replaceChildren();
          container.textContent = source;
          try {
            mermaid.initialize({
              startOnLoad: false,
              theme: theme,
              securityLevel: 'loose'
            });
            if (typeof mermaid.run === 'function') {
              mermaid.run({ nodes: [container] }).catch(renderMermaidFallback);
            } else {
              mermaid.init(undefined, container);
            }
          } catch (error) {
            renderMermaidFallback();
          }
        };

        try {
          if (typeof mermaid !== 'undefined') {
            rememberMermaidSource();
            mermaid.initialize({
              startOnLoad: true,
              theme: '\(theme)',
              securityLevel: 'loose'
            });
          } else {
            renderMermaidFallback();
          }
        } catch (error) {
          renderMermaidFallback();
        }
      </script>
      """
    } else {
      mermaidScriptTag = ""
      bodyContent = """
      <div class="mermaid fallback-container" role="status">
        <strong>\(fallbackTitle)</strong>
        <p>\(fallbackMessage)</p>
        <pre class="fallback">\(escapedCode)</pre>
      </div>
      """
    }

    return """
    <!DOCTYPE html>
    <html>
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      \(mermaidScriptTag)
      <style>
        :root {
          --mermaid-foreground: \(MermaidThemeValues.foreground(isDark: isDark));
          --mermaid-fallback-background: \(MermaidThemeValues.fallbackBackground(isDark: isDark));
        }
        body {
          margin: 0;
          padding: 16px;
          background: transparent;
          display: flex;
          flex-direction: column;
          justify-content: center;
          align-items: center;
          font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
          color: var(--mermaid-foreground);
        }
        .mermaid {
          width: 100%;
          text-align: center;
        }
        .fallback-container {
          text-align: left;
        }
        .fallback-container strong {
          display: block;
          margin-bottom: 8px;
        }
        .fallback-container p {
          margin: 0 0 10px;
        }
        pre.fallback {
          font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace;
          font-size: 13px;
          background: var(--mermaid-fallback-background);
          padding: 12px;
          border-radius: 8px;
          white-space: pre-wrap;
          word-break: break-word;
        }
          \(ThinRedScrollbarWebStyle.css)
      </style>
    </head>
    <body>
      \(bodyContent)
    </body>
    </html>
    """
  }

  private func htmlEscaped(_ value: String) -> String {
    value
      .replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
      .replacingOccurrences(of: "\"", with: "&quot;")
      .replacingOccurrences(of: "'", with: "&#39;")
  }
}

private enum MermaidThemeValues {
  static func name(isDark: Bool) -> String {
    isDark ? "dark" : "default"
  }

  static func foreground(isDark: Bool) -> String {
    isDark ? "#ECEFF4" : "#2E3440"
  }

  static func fallbackBackground(isDark: Bool) -> String {
    isDark ? "#1E222A" : "#F0F2F5"
  }
}
