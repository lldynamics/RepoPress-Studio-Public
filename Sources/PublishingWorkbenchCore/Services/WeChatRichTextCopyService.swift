import AppKit
import Foundation

/// Service for converting Markdown content into inlined-CSS HTML tailored for
/// one-click rich text pasting into WeChat Official Accounts, Zhihu, and other rich text editors.
public struct WeChatRichTextCopyService: Sendable {
  public struct Theme: Equatable, Sendable {
    public var primaryColor: String
    public var secondaryColor: String
    public var codeBackgroundColor: String
    public var quoteBackgroundColor: String

    public init(
      primaryColor: String = "#007aff",
      secondaryColor: String = "#5ac8fa",
      codeBackgroundColor: String = "#282c34",
      quoteBackgroundColor: String = "#f8f9fa"
    ) {
      self.primaryColor = primaryColor
      self.secondaryColor = secondaryColor
      self.codeBackgroundColor = codeBackgroundColor
      self.quoteBackgroundColor = quoteBackgroundColor
    }

    public static let wechatGreen = Theme(
      primaryColor: "#07c160",
      secondaryColor: "#10aeff",
      codeBackgroundColor: "#282c34",
      quoteBackgroundColor: "#f6ffed"
    )

    public static let zhihuBlue = Theme(
      primaryColor: "#0066ff",
      secondaryColor: "#3385ff",
      codeBackgroundColor: "#282c34",
      quoteBackgroundColor: "#f4f8fb"
    )

    public static let elegantClassic = Theme(
      primaryColor: "#007aff",
      secondaryColor: "#5856d6",
      codeBackgroundColor: "#282c34",
      quoteBackgroundColor: "#f8f9fa"
    )
  }

  public init() {}

  /// Converts markdown into styled inlined-CSS HTML.
  public static func renderHTML(
    markdown: String,
    title: String? = nil,
    theme: Theme = .elegantClassic
  ) -> String {
    WeChatRichTextCopyService().generateInlinedHTML(markdown: markdown, title: title, theme: theme)
  }

  /// Copies styled HTML and plain markdown into the macOS system pasteboard.
  @MainActor
  public static func copyToPasteboard(
    markdown: String,
    title: String? = nil,
    theme: Theme = .elegantClassic,
    pasteboard: NSPasteboard = .general
  ) -> Bool {
    let html = renderHTML(markdown: markdown, title: title, theme: theme)
    pasteboard.clearContents()
    var success = true
    success = pasteboard.setString(html, forType: .html) && success
    success = pasteboard.setString(markdown, forType: .string) && success
    return success
  }

  /// Generates the full HTML with embedded inlined CSS attributes.
  public func generateInlinedHTML(
    markdown: String,
    title: String? = nil,
    theme: Theme = .elegantClassic
  ) -> String {
    var bodyHTML = MarkdownHTMLRenderingService.renderPreviewBodyAllowingSanitizedHTML(markdown)
    bodyHTML = inlineStyles(in: bodyHTML, theme: theme)

    var headerHTML = ""
    if let title, !title.trimmingCharacters(in: .whitespaces).isEmpty {
      headerHTML = "<h1 style=\"font-size: 22px; font-weight: 700; color: #111111; margin: 28px 0 18px 0; padding-bottom: 8px; border-bottom: 2px solid \(theme.primaryColor); text-align: center; line-height: 1.4;\">\(escapeHTML(title))</h1>\n"
    }

    return """
    <!DOCTYPE html>
    <html>
    <head><meta charset="utf-8"></head>
    <body>
    <section style="font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, 'PingFang SC', 'Hiragino Sans GB', 'Microsoft YaHei', sans-serif; font-size: 15px; line-height: 1.8; color: #2b2b2b; letter-spacing: 0.5px; word-break: break-word; text-align: justify; padding: 10px;">
    \(headerHTML)\(bodyHTML)
    </section>
    </body>
    </html>
    """
  }

  // MARK: - Inlining Style Transformations

  private func inlineStyles(in rawHTML: String, theme: Theme) -> String {
    var html = rawHTML

    let rules: [(pattern: String, replacement: String)] = [
      // H1
      (#"(?i)<h1(?:\s+[^>]*)?>"#, "<h1 style=\"font-size: 21px; font-weight: 700; color: #111; margin: 28px 0 16px 0; padding-bottom: 8px; border-bottom: 2px solid \(theme.primaryColor); text-align: center; line-height: 1.4;\">"),
      // H2
      (#"(?i)<h2(?:\s+[^>]*)?>"#, "<h2 style=\"font-size: 18px; font-weight: 600; color: #111; margin: 26px 0 14px 0; padding-left: 12px; border-left: 4px solid \(theme.primaryColor); line-height: 1.5;\">"),
      // H3
      (#"(?i)<h3(?:\s+[^>]*)?>"#, "<h3 style=\"font-size: 16px; font-weight: 600; color: #222; margin: 20px 0 10px 0; line-height: 1.5;\">"),
      // H4..H6
      (#"(?i)<h4(?:\s+[^>]*)?>"#, "<h4 style=\"font-size: 15px; font-weight: 600; color: #333; margin: 18px 0 8px 0;\">"),
      (#"(?i)<h5(?:\s+[^>]*)?>"#, "<h5 style=\"font-size: 14.5px; font-weight: 600; color: #444; margin: 16px 0 6px 0;\">"),
      (#"(?i)<h6(?:\s+[^>]*)?>"#, "<h6 style=\"font-size: 14px; font-weight: 600; color: #555; margin: 14px 0 6px 0;\">"),
      // P
      (#"(?i)<p(?:\s+[^>]*)?>"#, "<p style=\"margin: 14px 0; line-height: 1.8; color: #2b2b2b;\">"),
      // Blockquote
      (#"(?i)<blockquote(?:\s+[^>]*)?>"#, "<blockquote style=\"margin: 18px 0; padding: 12px 18px; border-left: 4px solid \(theme.primaryColor); background-color: \(theme.quoteBackgroundColor); color: #555555; border-radius: 0 6px 6px 0; font-size: 14.5px; line-height: 1.7;\">"),
      // Pre / Code block
      (#"(?i)<pre><code(?:\s+[^>]*)?>"#, "<pre style=\"background-color: \(theme.codeBackgroundColor); color: #abb2bf; padding: 14px 16px; border-radius: 8px; overflow-x: auto; font-family: Menlo, Monaco, Consolas, 'Courier New', monospace; font-size: 13px; line-height: 1.6; margin: 18px 0; white-space: pre-wrap; word-break: break-all;\"><code style=\"font-family: inherit; color: inherit; background: transparent; padding: 0;\">"),
      (#"(?i)<pre(?:\s+[^>]*)?>"#, "<pre style=\"background-color: \(theme.codeBackgroundColor); color: #abb2bf; padding: 14px 16px; border-radius: 8px; overflow-x: auto; font-family: Menlo, Monaco, Consolas, 'Courier New', monospace; font-size: 13px; line-height: 1.6; margin: 18px 0; white-space: pre-wrap; word-break: break-all;\">"),
      // Inline Code (standalone <code>)
      (#"(?i)<code(?:\s+[^>]*)?>"#, "<code style=\"background-color: #f1f2f4; color: #d63384; padding: 2px 6px; border-radius: 4px; font-family: Menlo, Monaco, Consolas, monospace; font-size: 13.5px;\">"),
      // UL & OL
      (#"(?i)<ul(?:\s+[^>]*)?>"#, "<ul style=\"margin: 14px 0; padding-left: 24px; line-height: 1.8; list-style-type: disc;\">"),
      (#"(?i)<ol(?:\s+[^>]*)?>"#, "<ol style=\"margin: 14px 0; padding-left: 24px; line-height: 1.8; list-style-type: decimal;\">"),
      // LI
      (#"(?i)<li(?:\s+[^>]*)?>"#, "<li style=\"margin: 4px 0; color: #2b2b2b;\">"),
      // Table
      (#"(?i)<table(?:\s+[^>]*)?>"#, "<table style=\"border-collapse: collapse; width: 100%; margin: 18px 0; font-size: 14px; border: 1px solid #e1e4e8;\">"),
      // TH
      (#"(?i)<th(?:\s+[^>]*)?>"#, "<th style=\"background-color: #f6f8fa; font-weight: 600; padding: 9px 14px; border: 1px solid #e1e4e8; text-align: left; color: #24292e;\">"),
      // TD
      (#"(?i)<td(?:\s+[^>]*)?>"#, "<td style=\"padding: 9px 14px; border: 1px solid #e1e4e8; color: #333;\">"),
      // Links
      (#"(?i)<a(?:\s+href=\"([^\"]*)\")(?:\s+[^>]*)?>"#, "<a href=\"$1\" style=\"color: \(theme.primaryColor); text-decoration: none; border-bottom: 1px solid \(theme.primaryColor); word-break: break-all;\">"),
      // Strong / B
      (#"(?i)<strong(?:\s+[^>]*)?>"#, "<strong style=\"font-weight: 700; color: #111111;\">"),
      (#"(?i)<b(?:\s+[^>]*)?>"#, "<b style=\"font-weight: 700; color: #111111;\">"),
      // HR
      (#"(?i)<hr(?:\s+[^>]*)?>"#, "<hr style=\"border: none; border-top: 1px solid #e5e5e5; margin: 28px 0;\">"),
      // IMG
      (#"(?i)<img(?:\s+src=\"([^\"]*)\")(?:\s+alt=\"([^\"]*)\")?(?:\s+[^>]*)?>"#, "<img src=\"$1\" alt=\"$2\" style=\"max-width: 100%; height: auto; border-radius: 6px; margin: 16px auto; display: block;\">")
    ]

    for (pattern, replacement) in rules {
      if let regex = try? NSRegularExpression(pattern: pattern) {
        let ns = html as NSString
        html = regex.stringByReplacingMatches(
          in: html,
          range: NSRange(location: 0, length: ns.length),
          withTemplate: replacement
        )
      }
    }

    return html
  }

  private func escapeHTML(_ text: String) -> String {
    text
      .replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
      .replacingOccurrences(of: "\"", with: "&quot;")
      .replacingOccurrences(of: "'", with: "&#39;")
  }
}
