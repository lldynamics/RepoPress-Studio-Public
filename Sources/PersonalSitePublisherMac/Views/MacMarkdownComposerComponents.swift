import Foundation
import PublishingWorkbenchCore
import SwiftUI
import WebKit

struct SelectionActionBar: View {
  let selectionAIActionMenuItems: [AIPublishingActionMenuItem]
  let isSelectionAIActionRunning: Bool
  let activeSelectionActionName: String?
  let hasLatestAssistantMessage: Bool
  let selectionActionMessage: String
  let onSelectSelectionAction: (AIPublishingActionKind) -> Void
  let onApplyLatestAIReply: () -> Void
  let onInsertImages: () -> Void
  let onCheckSelectedPublicRisk: () -> Void
  let availabilityForSelectionAction: (AIPublishingActionKind) -> AIPublishingActionAvailabilityPresentation

  var body: some View {
    HStack(spacing: 6) {
      Menu {
        ForEach(selectionAIActionMenuItems) { item in
          let availability = availabilityForSelectionAction(item.kind)
          Button {
            onSelectSelectionAction(item.kind)
          } label: {
            Label(item.kind.localizedDisplayName, systemImage: item.systemImage)
          }
          .disabled(!availability.isEnabled)
          .help(availability.unavailableReason ?? item.kind.localizedDisplayName)
        }
      } label: {
        Label(activeSelectionActionName ?? "AI 编辑", systemImage: "sparkles")
      }
      .disabled(isSelectionAIActionRunning)

      Button {
        onApplyLatestAIReply()
      } label: {
        Label("应用 AI 回复", systemImage: "text.badge.checkmark")
      }
      .disabled(!hasLatestAssistantMessage)

      Button {
        onInsertImages()
      } label: {
        Label("插图", systemImage: "photo.badge.plus")
      }

      Button {
        onCheckSelectedPublicRisk()
      } label: {
        Label("公开风险", systemImage: "lock.shield")
      }

      if !selectionActionMessage.isEmpty {
        Text(selectionActionMessage)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
    }
    .font(.caption)
    .padding(.horizontal, 10)
    .padding(.vertical, 7)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
    .shadow(radius: 8, y: 2)
  }
}

struct FindReplaceBar: View {
  @Binding var findQuery: String
  @Binding var replacementText: String
  @Binding var isFindCaseSensitive: Bool

  let canUseFindReplace: Bool
  let findReplaceMessage: String
  let onFindNext: () -> Void
  let onReplaceCurrentOrNext: () -> Void
  let onReplaceAll: () -> Void
  let onDismiss: () -> Void

  @FocusState private var isFindFieldFocused: Bool

  var body: some View {
    HStack(spacing: 8) {
      TextField("查找", text: $findQuery)
        .textFieldStyle(.roundedBorder)
        .frame(width: 180)
        .focused($isFindFieldFocused)
        .accessibilityLabel("查找文本")
        .accessibilityValue(findQuery.nilIfEmpty ?? "未输入")

      TextField("替换为", text: $replacementText)
        .textFieldStyle(.roundedBorder)
        .frame(width: 180)
        .accessibilityLabel("替换文本")
        .accessibilityValue(replacementText.nilIfEmpty ?? "未输入")

      Toggle(isOn: $isFindCaseSensitive) {
        Image(systemName: "textformat")
      }
      .toggleStyle(.button)
      .help("区分大小写")
      .accessibilityLabel("区分大小写")
      .accessibilityValue(isFindCaseSensitive ? "开启" : "关闭")

      Button {
        onFindNext()
      } label: {
        Image(systemName: "chevron.down")
      }
      .disabled(!canUseFindReplace)
      .help("查找下一个")
      .accessibilityLabel("查找下一个")

      Button {
        onReplaceCurrentOrNext()
      } label: {
        Label("替换", systemImage: "arrow.triangle.2.circlepath")
      }
      .disabled(!canUseFindReplace)
      .accessibilityLabel("替换当前匹配")

      Button {
        onReplaceAll()
      } label: {
        Label("全部替换", systemImage: "arrow.triangle.2.circlepath")
      }
      .disabled(!canUseFindReplace)
      .accessibilityLabel("全部替换")

      if !findReplaceMessage.isEmpty {
        Text(findReplaceMessage)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }

      Spacer()

      Button {
        onDismiss()
      } label: {
        Image(systemName: "xmark")
      }
      .buttonStyle(.borderless)
      .help("关闭查找替换")
      .accessibilityLabel("关闭查找替换")
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 7)
    .background(.bar)
    .onAppear {
      isFindFieldFocused = true
    }
  }
}

struct MarkdownPreviewPane: View {
  let draft: ArticleDraft
  let profile: SiteProfile
  @AppStorage("markdownEditorPreviewTheme") private var previewThemeRaw = MarkdownPreviewTheme.github.rawValue
  @State private var htmlDocument = ""
  @State private var renderWorkItem: DispatchWorkItem?
  @State private var renderGeneration = 0

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 10) {
        HStack(alignment: .top) {
          Text(draft.title)
            .font(.title.weight(.semibold))
            .textSelection(.enabled)

          Spacer()

          Picker("预览主题", selection: previewThemeBinding) {
            ForEach(MarkdownPreviewTheme.allCases) { theme in
              Text(theme.title).tag(theme)
            }
          }
          .pickerStyle(.menu)
          .labelsHidden()
          .accessibilityLabel("预览主题")
          .accessibilityValue(previewThemeBinding.wrappedValue.title)
        }

        Text(profile.markdownPath(for: draft))
          .font(.callout.monospaced())
          .foregroundStyle(.secondary)
          .textSelection(.enabled)

        if !draft.summary.isEmpty {
          Text(draft.summary)
            .font(.callout)
            .foregroundStyle(.secondary)
        }

        Divider()
      }
      .padding(14)
      .background(.bar)

      MarkdownPreviewWebView(html: htmlDocument)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .onAppear(perform: scheduleHTMLRender)
    .onChange(of: previewRenderInput) { _, _ in
      scheduleHTMLRender()
    }
  }

  private var previewTheme: MarkdownPreviewTheme {
    MarkdownPreviewTheme(rawValue: previewThemeRaw) ?? .github
  }

  private var previewThemeBinding: Binding<MarkdownPreviewTheme> {
    Binding(
      get: { previewTheme },
      set: { previewThemeRaw = $0.rawValue }
    )
  }

  private var previewRenderInput: String {
    [draft.bodyMarkdown, previewTheme.rawValue].joined(separator: "\u{1F}")
  }

  private func scheduleHTMLRender() {
    renderWorkItem?.cancel()
    renderGeneration += 1
    let generation = renderGeneration
    let markdown = draft.bodyMarkdown
    let theme = previewTheme
    let workItem = DispatchWorkItem {
      let html = MarkdownPreviewHTMLRenderer.document(markdown: markdown, theme: theme)
      DispatchQueue.main.async {
        guard generation == renderGeneration else { return }
        htmlDocument = html
        renderWorkItem = nil
      }
    }
    renderWorkItem = workItem
    DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.25, execute: workItem)
  }
}

private enum MarkdownPreviewHTMLRenderer {
  static func document(markdown: String, theme: MarkdownPreviewTheme) -> String {
    let body = theme.decorate(markdownHTMLBody(for: markdown))
    return """
    <!doctype html>
    <html>
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src data:; font-src 'none'; media-src 'none'; connect-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'" />
        <style>\(theme.styles)</style>
      </head>
      <body>
        <article class="markdown-content">\(body)</article>
      </body>
    </html>
    """
  }

  private static func markdownHTMLBody(for markdown: String) -> String {
    autoreleasepool {
      guard #available(macOS 12.0, *) else {
        return preformattedFallback(from: markdown)
      }
      do {
        let attributed = try NSAttributedString(markdown: markdown)
        let data = try attributed.data(
          from: NSRange(location: 0, length: attributed.length),
          documentAttributes: [.documentType: NSAttributedString.DocumentType.html]
        )
        guard let raw = String(data: data, encoding: .utf8) else {
          return preformattedFallback(from: markdown)
        }
        if let bodyRangeStart = raw.range(of: "<body", options: .caseInsensitive),
           let bodyStart = raw.range(of: ">", range: bodyRangeStart.upperBound..<raw.endIndex),
           let bodyEnd = raw.range(of: "</body", options: .caseInsensitive, range: bodyStart.upperBound..<raw.endIndex) {
          return String(raw[bodyStart.upperBound..<bodyEnd.lowerBound])
        }
        return raw
      } catch {
        return preformattedFallback(from: markdown)
      }
    }
  }

  private static func preformattedFallback(from markdown: String) -> String {
    "<pre><code>\(escapeHTML(markdown))</code></pre>"
  }

  private static func escapeHTML(_ value: String) -> String {
    value
      .replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
      .replacingOccurrences(of: "\"", with: "&quot;")
      .replacingOccurrences(of: "'", with: "&#39;")
  }
}

enum MarkdownPreviewTheme: String, CaseIterable, Identifiable {
  case github
  case githubDark
  case simple

  var id: String { rawValue }

  var title: String {
    switch self {
    case .github:
      return "GitHub"
    case .githubDark:
      return "GitHub Dark"
    case .simple:
      return "简洁白"
    }
  }

  var styles: String {
    switch self {
    case .github:
      return """
      :root { color-scheme: light; }
      body { margin: 0; font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; line-height: 1.7; background: #fff; color: #24292f; padding: 20px; }
      .markdown-content { max-width: 860px; margin: 0 auto; }
      .markdown-content pre { background: #f6f8fa; border: 1px solid #d0d7de; border-radius: 8px; padding: 12px; }
      .markdown-content code { font-family: SFMono-Regular, Menlo, Monaco, Consolas, monospace; }
      .markdown-content a { color: #0969da; }
      .markdown-content table { border-collapse: collapse; margin: 12px 0; }
      .markdown-content th, .markdown-content td { border: 1px solid #d0d7de; padding: 6px 10px; }
      .markdown-content blockquote { border-left: 4px solid #d0d7de; margin: 12px 0; padding: 8px 12px; background: #f6f8fa; color: #57606a; }
      """
    case .githubDark:
      return """
      :root { color-scheme: dark; }
      body { margin: 0; font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; line-height: 1.7; background: #0d1117; color: #c9d1d9; padding: 20px; }
      .markdown-content { max-width: 860px; margin: 0 auto; }
      .markdown-content pre { background: #161b22; border: 1px solid #30363d; border-radius: 8px; padding: 12px; }
      .markdown-content code { font-family: SFMono-Regular, Menlo, Monaco, Consolas, monospace; }
      .markdown-content a { color: #58a6ff; }
      .markdown-content table { border-collapse: collapse; margin: 12px 0; }
      .markdown-content th, .markdown-content td { border: 1px solid #30363d; padding: 6px 10px; }
      .markdown-content blockquote { border-left: 4px solid #30363d; margin: 12px 0; padding: 8px 12px; background: #161b22; color: #8b949e; }
      """
    case .simple:
      return """
      :root { color-scheme: light; }
      body { margin: 0; font-family: -apple-system, BlinkMacSystemFont, 'PingFang SC', 'Hiragino Sans GB', sans-serif; line-height: 1.85; background: #fffef8; color: #202020; padding: 24px; }
      .markdown-content { max-width: 900px; margin: 0 auto; }
      .markdown-content pre { border: 1px solid #ddd; border-radius: 6px; padding: 12px; background: #f7f6f2; }
      .markdown-content code { font-family: Menlo, SFMono-Regular, Consolas, monospace; }
      .markdown-content h1, .markdown-content h2, .markdown-content h3 { line-height: 1.25; }
      .markdown-content img { max-width: 100%; }
      """
    }
  }

  func decorate(_ html: String) -> String {
    html
  }
}

struct MarkdownPreviewWebView: NSViewRepresentable {
  let html: String

  @MainActor
  final class Coordinator: NSObject, WKNavigationDelegate {
    var lastLoadedHTML: String?

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
      if navigationAction.navigationType == .linkActivated {
        _ = ExternalURLOpener.open(url)
      }
      decisionHandler(.cancel)
    }
  }

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  func makeNSView(context: Context) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.defaultWebpagePreferences.allowsContentJavaScript = false
    configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
    let view = WKWebView(frame: .zero, configuration: configuration)
    view.navigationDelegate = context.coordinator
    view.setValue(false, forKey: "drawsBackground")
    return view
  }

  func updateNSView(_ nsView: WKWebView, context: Context) {
    guard context.coordinator.lastLoadedHTML != html else { return }
    context.coordinator.lastLoadedHTML = html
    nsView.loadHTMLString(html, baseURL: nil)
  }
}
