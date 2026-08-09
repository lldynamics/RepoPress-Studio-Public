import SwiftUI
import WebKit

struct MermaidDiagramRenderWebView: NSViewRepresentable {
  let mermaidCode: String
  @Environment(\.colorScheme) private var colorScheme

  func makeNSView(context: Context) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    let webView = WKWebView(frame: .zero, configuration: configuration)
    webView.setValue(false, forKey: "drawsBackground")
    return webView
  }

  func updateNSView(_ nsView: WKWebView, context: Context) {
    let html = htmlContent(for: mermaidCode, isDark: colorScheme == .dark)
    nsView.loadHTMLString(html, baseURL: nil)
  }

  private func htmlContent(for code: String, isDark: Bool) -> String {
    let theme = isDark ? "dark" : "default"
    let escapedCode = code
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "`", with: "\\`")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")

    let mermaidScriptTag: String
    if let localURL = Bundle.main.url(forResource: "mermaid.min", withExtension: "js") {
      mermaidScriptTag = "<script src=\"\(localURL.absoluteString)\"></script>"
    } else {
      mermaidScriptTag = "<script src=\"https://cdn.jsdelivr.net/npm/mermaid@10/dist/mermaid.min.js\"></script>"
    }

    return """
    <!DOCTYPE html>
    <html>
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      \(mermaidScriptTag)
      <style>
        body {
          margin: 0;
          padding: 16px;
          background: transparent;
          display: flex;
          flex-direction: column;
          justify-content: center;
          align-items: center;
          font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
          color: \(isDark ? "#ECEFF4" : "#2E3440");
        }
        .mermaid {
          width: 100%;
          text-align: center;
        }
        pre.fallback {
          font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace;
          font-size: 13px;
          background: \(isDark ? "#1E222A" : "#F0F2F5");
          padding: 12px;
          border-radius: 8px;
          white-space: pre-wrap;
          word-break: break-word;
        }
        \(ThinRedScrollbarWebStyle.css)
      </style>
    </head>
    <body>
      <div class="mermaid">
      \(escapedCode)
      </div>
      <script>
        try {
          if (typeof mermaid !== 'undefined') {
            mermaid.initialize({
              startOnLoad: true,
              theme: '\(theme)',
              securityLevel: 'loose'
            });
          } else {
            document.querySelector('.mermaid').innerHTML = '<pre class="fallback">\(escapedCode)</pre>';
          }
        } catch (e) {
          document.querySelector('.mermaid').innerHTML = '<pre class="fallback">\(escapedCode)</pre>';
        }
      </script>
    </body>
    </html>
    """
  }
}
