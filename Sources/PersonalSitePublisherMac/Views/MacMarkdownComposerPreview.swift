import AppKit
import Foundation
import PublishingWorkbenchCore
import SwiftUI
import UniformTypeIdentifiers
import WebKit
#if canImport(Darwin)
import Darwin
#endif
struct MarkdownPreviewPane: View {
  let draft: ArticleDraft
  let profile: SiteProfile
  let showsSynchronizedScrollingControl: Bool
  @Binding var isSynchronizedScrollingEnabled: Bool
  let scrollSyncUpdate: MarkdownScrollSyncUpdate?
  let scrollRestorationUpdate: MarkdownScrollSyncUpdate?
  let onScrollProgressChanged: (Double) -> Void
  let onSourceLocationSelected: (Int) -> Void
  @Environment(\.colorScheme) private var colorScheme
  @AppStorage("markdownEditorPreviewTheme") private var previewThemeRaw = MarkdownPreviewTheme.system.rawValue
  @AppStorage(MarkdownEditorComfortPreferences.automaticPreviewRefreshEnabledKey)
  private var isAutomaticPreviewRefreshEnabled = MarkdownEditorComfortConfiguration
    .defaultAutomaticPreviewRefreshEnabled
  @State private var htmlDocument = ""
  @State private var assetResources: [MarkdownPreviewAssetResource] = []
  @State private var renderID: UUID?
  @State private var renderTask: Task<Void, Never>?
  @State private var renderTaskIsAutomatic = false
  @State private var renderGeneration: UInt64 = 0
  @State private var isRendering = false
  @State private var renderErrorMessage: String?
  @State private var siteStyleSourcePaths: [String] = []

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 10) {
        Label("预览", systemImage: "doc.richtext")
          .font(.callout.weight(.semibold))

        if isRendering {
          ProgressView()
            .controlSize(.small)
            .accessibilityLabel("正在更新文章预览")
        }

        Spacer()

        Button {
          scheduleHTMLRender(immediate: true)
        } label: {
          Image(systemName: "arrow.clockwise")
        }
        .help(String(localized: "手动刷新文章预览"))
        .accessibilityLabel("手动刷新文章预览")
        .accessibilityIdentifier("markdown-preview-refresh")
        .disabled(isRendering)

        if showsSynchronizedScrollingControl {
          ViewThatFits(in: .horizontal) {
            synchronizedScrollingToggle(showsLabel: true)
              .fixedSize()
            synchronizedScrollingToggle(showsLabel: false)
              .fixedSize()
          }
        }

        if previewTheme == .site {
          if siteStyleSourcePaths.isEmpty {
            Label("未找到站点 CSS", systemImage: "exclamationmark.triangle")
              .font(.caption)
              .foregroundStyle(.secondary)
          } else {
            Label(
              String(localized: "\(siteStyleSourcePaths.count) 个站点样式"),
              systemImage: "paintbrush"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .help(siteStyleSourcePaths.joined(separator: "\n"))
          }
        }

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
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .background(.bar)

      Divider()

      previewContent
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .accessibilityLabel(String(localized: "文章预览：\(draft.title)"))
    .onAppear {
      scheduleHTMLRender(immediate: true)
    }
    .onChange(of: previewRenderInput) { _, _ in
      scheduleHTMLRender(isAutomatic: true)
    }
    .onChange(of: isAutomaticPreviewRefreshEnabled) { _, isEnabled in
      if isEnabled {
        scheduleHTMLRender(immediate: true, isAutomatic: true)
      } else {
        cancelAutomaticHTMLRender()
      }
    }
    .onDisappear {
      renderTask?.cancel()
      renderTask = nil
    }
  }

  private func synchronizedScrollingToggle(showsLabel: Bool) -> some View {
    Toggle(isOn: $isSynchronizedScrollingEnabled) {
      if showsLabel {
        Label("同步滚动", systemImage: "arrow.up.and.down.text.horizontal")
      } else {
        Image(systemName: "arrow.up.and.down.text.horizontal")
      }
    }
    .toggleStyle(.button)
    .help(
      isSynchronizedScrollingEnabled
        ? String(localized: "关闭编辑与预览同步滚动")
        : String(localized: "开启编辑与预览同步滚动")
    )
    .accessibilityLabel("编辑与预览同步滚动")
    .accessibilityValue(
      isSynchronizedScrollingEnabled ? String(localized: "开启") : String(localized: "关闭")
    )
  }

  private var previewTheme: MarkdownPreviewTheme {
    MarkdownPreviewTheme(rawValue: previewThemeRaw) ?? .system
  }

  private var previewEmptyStateMessage: LocalizedStringKey {
    if isAutomaticPreviewRefreshEnabled {
      return "正文发生变化后会自动重新生成，也可以手动重试。"
    }
    return "自动刷新已关闭，可以手动生成或刷新预览。"
  }

  private var previewThemeBinding: Binding<MarkdownPreviewTheme> {
    Binding(
      get: { previewTheme },
      set: { previewThemeRaw = $0.rawValue }
    )
  }

  private var previewRenderInput: MarkdownPreviewRenderInput {
    MarkdownPreviewRenderInput(
      title: draft.title.trimmedForPublishing.nilIfEmpty ?? String(localized: "未命名文章"),
      markdown: draft.bodyMarkdown,
      attachments: draft.attachments,
      profile: profile,
      theme: previewTheme,
      isDarkAppearance: colorScheme == .dark
    )
  }

  @ViewBuilder
  private var previewContent: some View {
    if htmlDocument.isEmpty {
      if isRendering {
        VStack(spacing: 10) {
          ProgressView()
          Text("正在生成预览…")
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("正在生成文章预览")
      } else if let renderErrorMessage {
        previewFailure(message: renderErrorMessage, fillsAvailableSpace: true)
      } else {
        EmptyStateView(
          title: "预览尚未生成",
          message: previewEmptyStateMessage,
          systemImage: "doc.richtext",
          density: .inline,
          actionTitle: "生成预览",
          actionSystemImage: "arrow.clockwise",
          action: { scheduleHTMLRender(immediate: true) }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    } else {
      VStack(spacing: 0) {
        if let renderErrorMessage {
          previewFailure(message: renderErrorMessage, fillsAvailableSpace: false)
          Divider()
        }
        MarkdownPreviewWebView(
          html: htmlDocument,
          renderID: renderID,
          assetResources: assetResources,
          scrollSyncUpdate: isSynchronizedScrollingEnabled ? scrollSyncUpdate : nil,
          scrollRestorationUpdate: scrollRestorationUpdate,
          onScrollProgressChanged: onScrollProgressChanged,
          onSourceLocationSelected: onSourceLocationSelected
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
  }

  private func previewFailure(message: String, fillsAvailableSpace: Bool) -> some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: "exclamationmark.triangle")
        .foregroundStyle(WorkbenchTheme.risk)
      VStack(alignment: .leading, spacing: 3) {
        Text("预览生成失败")
          .font(.callout.weight(.semibold))
        Text(message)
          .font(.caption)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
      }
      Spacer()
      Button("重试") {
        scheduleHTMLRender(immediate: true)
      }
      .disabled(isRendering)
    }
    .padding(12)
    .frame(
      maxWidth: .infinity,
      maxHeight: fillsAvailableSpace ? .infinity : nil,
      alignment: fillsAvailableSpace ? .center : .topLeading
    )
    .background(WorkbenchTheme.risk.opacity(WorkbenchOpacity.warningBackground))
  }

  private func scheduleHTMLRender(immediate: Bool = false, isAutomatic: Bool = false) {
    guard MarkdownEditorAutomationPolicy.allows(
      isAutomatic: isAutomatic,
      isEnabled: isAutomaticPreviewRefreshEnabled
    ) else {
      return
    }
    renderTask?.cancel()
    renderGeneration &+= 1
    let generation = renderGeneration
    let input = previewRenderInput
    renderTaskIsAutomatic = isAutomatic
    isRendering = true
    renderErrorMessage = nil

    renderTask = Task { @MainActor in
      defer {
        if renderGeneration == generation {
          renderTask = nil
          renderTaskIsAutomatic = false
          isRendering = false
        }
      }
      if !immediate {
        do {
          try await Task.sleep(for: .milliseconds(250))
        } catch {
          return
        }
      }
      guard !Task.isCancelled else { return }
      do {
        let snapshot = try await MarkdownPreviewRenderEngine.shared.render(input)
        guard !Task.isCancelled,
          renderGeneration == generation,
          previewRenderInput == input
        else { return }
        renderID = snapshot.id
        assetResources = snapshot.assetResources
        htmlDocument = snapshot.html
        siteStyleSourcePaths = snapshot.siteStyleSourcePaths
        renderErrorMessage = nil
      } catch is CancellationError {
        return
      } catch {
        guard renderGeneration == generation, previewRenderInput == input else { return }
        renderErrorMessage = error.localizedDescription
      }
    }
  }

  private func cancelAutomaticHTMLRender() {
    guard renderTaskIsAutomatic else { return }
    renderGeneration &+= 1
    renderTask?.cancel()
    renderTask = nil
    renderTaskIsAutomatic = false
    isRendering = false
  }
}
private struct MarkdownPreviewRenderInput: Hashable, Sendable {
  let title: String
  let markdown: String
  let attachments: [DraftAttachment]
  let profile: SiteProfile
  let theme: MarkdownPreviewTheme
  let isDarkAppearance: Bool
}

private struct MarkdownPreviewRenderCacheKey: Hashable, Sendable {
  let input: MarkdownPreviewRenderInput
  let assetResources: [MarkdownPreviewAssetResource]
  let siteStylesheet: SitePreviewStylesheet?
}

private struct MarkdownPreviewRenderSnapshot: Sendable {
  let id: UUID
  let html: String
  let assetResources: [MarkdownPreviewAssetResource]
  let siteStyleSourcePaths: [String]
}

private actor MarkdownPreviewRenderEngine {
  static let shared = MarkdownPreviewRenderEngine()
  private var cache = MarkdownPreviewRenderCache<
    MarkdownPreviewRenderCacheKey,
    MarkdownPreviewRenderSnapshot
  >(capacity: 4)

  func render(_ input: MarkdownPreviewRenderInput) throws -> MarkdownPreviewRenderSnapshot {
    try Task.checkCancellation()
    let resources = MarkdownPreviewAssetResource.resources(for: input.attachments)
    let siteStylesheet = input.theme == .site
      ? SitePreviewStyleService.load(for: input.profile)
      : nil
    let cacheKey = MarkdownPreviewRenderCacheKey(
      input: input,
      assetResources: resources,
      siteStylesheet: siteStylesheet
    )
    if let cachedSnapshot = cache.snapshot(for: cacheKey) {
      return cachedSnapshot
    }

    try Task.checkCancellation()
    let html = try MarkdownPreviewHTMLRenderer.document(
      title: input.title,
      markdown: input.markdown,
      attachments: input.attachments,
      previewURLByAttachmentID: Dictionary(
        uniqueKeysWithValues: resources.map { ($0.attachmentID, $0.previewURLString) }
      ),
      theme: input.theme,
      isDarkAppearance: input.isDarkAppearance,
      siteStylesheet: siteStylesheet
    )
    try Task.checkCancellation()
    let snapshot = MarkdownPreviewRenderSnapshot(
      id: UUID(),
      html: html,
      assetResources: resources,
      siteStyleSourcePaths: siteStylesheet?.sourcePaths ?? []
    )
    cache.insert(snapshot, for: cacheKey)
    return snapshot
  }
}

private enum MarkdownPreviewHTMLRenderer {
  static func document(
    title: String,
    markdown: String,
    attachments: [DraftAttachment],
    previewURLByAttachmentID: [UUID: String],
    theme: MarkdownPreviewTheme,
    isDarkAppearance: Bool,
    siteStylesheet: SitePreviewStylesheet?
  ) throws -> String {
    var renderedBlocks: [String] = []
    let bodyMarkdown = MarkdownPreviewTitleService.bodyMarkdown(
      title: title,
      markdown: markdown
    )
    for block in MarkdownExtendedPreviewService.blocks(in: bodyMarkdown) {
      try Task.checkCancellation()
      switch block {
      case let .markdown(markdownBlock):
        let prepared = MarkdownPreviewAssetService.prepare(
          markdown: markdownBlock,
          attachments: attachments,
          previewURLByAttachmentID: previewURLByAttachmentID
        )
        renderedBlocks.append(restoredAssetHTML(
          MarkdownHTMLRenderingService.renderPreviewBodyAllowingSanitizedHTML(prepared.markdown),
          replacements: prepared.replacements
        ))
      case let .mermaid(diagram):
        renderedBlocks.append(mermaidHTML(for: diagram))
      }
    }
    try Task.checkCancellation()
    let body = MarkdownPreviewSourceLinkService.annotatingHeadingLinks(
      in: theme.decorate(renderedBlocks.joined(separator: "\n")),
      sourceMarkdown: bodyMarkdown
    )
    let escapedTitle = escapeHTML(title)
    let previewStyles = theme.styles(
      isDarkAppearance: isDarkAppearance,
      siteStylesheet: siteStylesheet
    )
    return """
    <!doctype html>
    <html>
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src data: publisher-asset:; font-src 'none'; media-src publisher-asset:; connect-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'" />
        <title>\(escapedTitle)</title>
        <style>
          \(previewStyles)
          \(ThinRedScrollbarWebStyle.css)
        </style>
      </head>
      <body>
        <article class="markdown-content">
          <header class="article-header"><h1 class="article-title">\(escapedTitle)</h1></header>
          <div class="article-body">\(body)</div>
        </article>
      </body>
    </html>
    """
  }

  private static func markdownHTMLBody(for markdown: String) -> String {
    MarkdownHTMLRenderingService.renderBody(markdown)
  }

  private static func preformattedFallback(from markdown: String) -> String {
    "<pre><code>\(escapeHTML(markdown))</code></pre>"
  }

  private static func restoredAssetHTML(
    _ html: String,
    replacements: [MarkdownPreviewAssetHTMLReplacement]
  ) -> String {
    replacements.reduce(html) { partialResult, replacement in
      partialResult.replacingOccurrences(of: replacement.token, with: replacement.html)
    }
  }

  private static func mermaidHTML(for diagram: MarkdownMermaidDiagram) -> String {
    guard !diagram.nodes.isEmpty else {
      return "<section class=\"mermaid-diagram mermaid-fallback\"><strong>Mermaid 基础流程图预览</strong><span class=\"mermaid-note\">当前不是完整 Mermaid 渲染。</span>\(preformattedFallback(from: diagram.source))</section>"
    }

    let nodeWidth = 180.0
    let nodeHeight = 48.0
    let gap = 54.0
    let padding = 34.0
    let isHorizontal = diagram.direction == .leftRight
    let width = isHorizontal
      ? padding * 2 + Double(diagram.nodes.count) * nodeWidth + Double(max(0, diagram.nodes.count - 1)) * gap
      : padding * 2 + nodeWidth
    let height = isHorizontal
      ? padding * 2 + nodeHeight
      : padding * 2 + Double(diagram.nodes.count) * nodeHeight + Double(max(0, diagram.nodes.count - 1)) * gap

    var positions: [String: (x: Double, y: Double)] = [:]
    for (index, node) in diagram.nodes.enumerated() {
      positions[node.id] = isHorizontal
        ? (padding + Double(index) * (nodeWidth + gap), padding)
        : (padding, padding + Double(index) * (nodeHeight + gap))
    }

    let edges = diagram.edges.compactMap { edge -> String? in
      guard let start = positions[edge.from], let end = positions[edge.to] else { return nil }
      let x1 = isHorizontal ? start.x + nodeWidth : start.x + nodeWidth / 2
      let y1 = isHorizontal ? start.y + nodeHeight / 2 : start.y + nodeHeight
      let x2 = isHorizontal ? end.x : end.x + nodeWidth / 2
      let y2 = isHorizontal ? end.y + nodeHeight / 2 : end.y
      let label = edge.label.map {
        "<text class=\"edge-label\" x=\"\((x1 + x2) / 2)\" y=\"\((y1 + y2) / 2 - 6)\" text-anchor=\"middle\">\(escapeHTML($0))</text>"
      } ?? ""
      return "<line class=\"edge\" x1=\"\(x1)\" y1=\"\(y1)\" x2=\"\(x2)\" y2=\"\(y2)\" marker-end=\"url(#mermaid-arrow)\"/>\(label)"
    }
    .joined()

    let nodes = diagram.nodes.compactMap { node -> String? in
      guard let point = positions[node.id] else { return nil }
      return """
      <g class="node">
        <rect x="\(point.x)" y="\(point.y)" width="\(nodeWidth)" height="\(nodeHeight)" rx="10" />
        <text x="\(point.x + nodeWidth / 2)" y="\(point.y + nodeHeight / 2 + 5)" text-anchor="middle">\(escapeHTML(node.label))</text>
      </g>
      """
    }
    .joined()

    return """
    <section class="mermaid-diagram" aria-label="Mermaid 基础流程图预览">
      <div class="mermaid-title">Mermaid 基础流程图预览</div>
      <div class="mermaid-note">当前仅支持基础流程图预览，不是完整 Mermaid。</div>
      <svg viewBox="0 0 \(width) \(height)" role="img" aria-label="\(escapeHTML(diagram.nodes.map(\.label).joined(separator: "，")))">
        <defs><marker id="mermaid-arrow" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse"><path d="M 0 0 L 10 5 L 0 10 z" /></marker></defs>
        \(edges)
        \(nodes)
      </svg>
      <details><summary>查看 Mermaid 源码</summary>\(preformattedFallback(from: diagram.source))</details>
    </section>
    """
  }

  private static func escapeHTML(_ value: String) -> String {
    MarkupEscaping.html(value)
  }
}

enum MarkdownPreviewTheme: String, CaseIterable, Identifiable, Hashable, Sendable {
  case system
  case site
  case github
  case githubDark
  case simple

  var id: String { rawValue }

  var title: String {
    switch self {
    case .system:
      return String(localized: "跟随系统")
    case .site:
      return String(localized: "真实站点 CSS")
    case .github:
      return "GitHub"
    case .githubDark:
      return "GitHub Dark"
    case .simple:
      return String(localized: "简洁白")
    }
  }

  func styles(
    isDarkAppearance: Bool,
    siteStylesheet: SitePreviewStylesheet? = nil
  ) -> String {
    switch self {
    case .system:
      if isDarkAppearance {
        return """
        :root { color-scheme: dark; }
        body { margin: 0; font-family: -apple-system, BlinkMacSystemFont, 'PingFang SC', 'Hiragino Sans GB', sans-serif; line-height: 1.78; background: #171c17; color: #e3e8e1; padding: 22px; }
        .markdown-content { max-width: 860px; margin: 0; }
        .markdown-content a { color: #94c785; }
        .markdown-content pre { background: #222a21; border: 1px solid #3e4b3a; border-radius: 8px; padding: 12px; }
        .markdown-content code { font-family: SFMono-Regular, Menlo, Monaco, Consolas, monospace; }
        .markdown-content table { border-collapse: collapse; margin: 12px 0; }
        .markdown-content th, .markdown-content td { border: 1px solid #3e4b3a; padding: 6px 10px; }
        .markdown-content blockquote { border-left: 4px solid #76a96b; margin: 12px 0; padding: 8px 12px; background: #222d21; color: #c5d3c1; }
        \(extendedPreviewStyles)
        """
      }
      return """
      :root { color-scheme: light; }
      body { margin: 0; font-family: -apple-system, BlinkMacSystemFont, 'PingFang SC', 'Hiragino Sans GB', sans-serif; line-height: 1.78; background: #f7f9f5; color: #253126; padding: 22px; }
      .markdown-content { max-width: 860px; margin: 0; }
      .markdown-content a { color: #427a38; }
      .markdown-content pre { background: #edf2e9; border: 1px solid #ced9c8; border-radius: 8px; padding: 12px; }
      .markdown-content code { font-family: SFMono-Regular, Menlo, Monaco, Consolas, monospace; }
      .markdown-content table { border-collapse: collapse; margin: 12px 0; }
      .markdown-content th, .markdown-content td { border: 1px solid #ced9c8; padding: 6px 10px; }
      .markdown-content blockquote { border-left: 4px solid #6f9b65; margin: 12px 0; padding: 8px 12px; background: #e9f1e5; color: #4d624f; }
      \(extendedPreviewStyles)
      """
    case .site:
      let base = """
      :root { color-scheme: light dark; }
      body { margin: 0; padding: 22px; font-family: -apple-system, BlinkMacSystemFont, 'PingFang SC', sans-serif; line-height: 1.7; }
      .markdown-content { max-width: 960px; margin: 0 auto; }
      .markdown-content img, .markdown-content video { max-width: 100%; height: auto; }
      .markdown-content table { border-collapse: collapse; }
      \(extendedPreviewStyles)
      """
      guard let siteStylesheet else {
        return base
      }
      return base + "\n\n" + siteStylesheet.css
    case .github:
      return """
      :root { color-scheme: light; }
      body { margin: 0; font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; line-height: 1.7; background: #fff; color: #24292f; padding: 20px; }
      .markdown-content { max-width: 860px; margin: 0; }
      .markdown-content pre { background: #f6f8fa; border: 1px solid #d0d7de; border-radius: 8px; padding: 12px; }
      .markdown-content code { font-family: SFMono-Regular, Menlo, Monaco, Consolas, monospace; }
      .markdown-content a { color: #0969da; }
      .markdown-content table { border-collapse: collapse; margin: 12px 0; }
      .markdown-content th, .markdown-content td { border: 1px solid #d0d7de; padding: 6px 10px; }
      .markdown-content blockquote { border-left: 4px solid #d0d7de; margin: 12px 0; padding: 8px 12px; background: #f6f8fa; color: #57606a; }
      \(extendedPreviewStyles)
      """
    case .githubDark:
      return """
      :root { color-scheme: dark; }
      body { margin: 0; font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; line-height: 1.7; background: #0d1117; color: #c9d1d9; padding: 20px; }
      .markdown-content { max-width: 860px; margin: 0; }
      .markdown-content pre { background: #161b22; border: 1px solid #30363d; border-radius: 8px; padding: 12px; }
      .markdown-content code { font-family: SFMono-Regular, Menlo, Monaco, Consolas, monospace; }
      .markdown-content a { color: #58a6ff; }
      .markdown-content table { border-collapse: collapse; margin: 12px 0; }
      .markdown-content th, .markdown-content td { border: 1px solid #30363d; padding: 6px 10px; }
      .markdown-content blockquote { border-left: 4px solid #30363d; margin: 12px 0; padding: 8px 12px; background: #161b22; color: #8b949e; }
      \(extendedPreviewStyles)
      """
    case .simple:
      return """
      :root { color-scheme: light; }
      body { margin: 0; font-family: -apple-system, BlinkMacSystemFont, 'PingFang SC', 'Hiragino Sans GB', sans-serif; line-height: 1.85; background: #fffef8; color: #202020; padding: 24px; }
      .markdown-content { max-width: 900px; margin: 0; }
      .markdown-content pre { border: 1px solid #ddd; border-radius: 6px; padding: 12px; background: #f7f6f2; }
      .markdown-content code { font-family: Menlo, SFMono-Regular, Consolas, monospace; }
      .markdown-content h1, .markdown-content h2, .markdown-content h3 { line-height: 1.25; }
      .markdown-content img { max-width: 100%; }
      \(extendedPreviewStyles)
      """
    }
  }

  func decorate(_ html: String) -> String {
    html
  }

  private var extendedPreviewStyles: String {
    """
    .article-header { margin: 0 0 1.5em; padding-bottom: .85em; border-bottom: 1px solid color-mix(in srgb, currentColor 16%, transparent); }
    .article-title { margin: 0; font-size: clamp(1.75em, 4vw, 2.25em); line-height: 1.18; letter-spacing: -.02em; overflow-wrap: anywhere; }
    .mermaid-diagram { margin: 18px 0; padding: 14px; border: 1px solid color-mix(in srgb, currentColor 18%, transparent); border-radius: 10px; overflow-x: auto; }
    .mermaid-title { font-weight: 600; margin-bottom: 8px; }
    .mermaid-note { display: block; margin: 0 0 8px; color: color-mix(in srgb, currentColor 66%, transparent); font-size: .88em; }
    .mermaid-diagram svg { width: 100%; min-width: 320px; max-height: 720px; }
    .mermaid-diagram .node rect { fill: color-mix(in srgb, currentColor 8%, transparent); stroke: color-mix(in srgb, currentColor 55%, transparent); stroke-width: 1.5; }
    .mermaid-diagram .node text, .mermaid-diagram .edge-label { fill: currentColor; font: 13px -apple-system, BlinkMacSystemFont, sans-serif; }
    .mermaid-diagram .edge { stroke: color-mix(in srgb, currentColor 65%, transparent); stroke-width: 1.6; }
    .mermaid-diagram marker path { fill: currentColor; }
    .mermaid-diagram details { margin-top: 8px; color: inherit; opacity: .75; }
    .local-katex { color: inherit; }
    .local-katex-inline { display: inline-block; padding: 0 .12em; font-family: STIX Two Math, Cambria Math, serif; }
    .local-katex-display { display: block; margin: 1em 0; text-align: center; font-family: STIX Two Math, Cambria Math, serif; font-size: 1.15em; overflow-x: auto; }
    .math-fraction { display: inline-flex; flex-direction: column; vertical-align: middle; text-align: center; line-height: 1.05; margin: 0 .12em; }
    .math-numerator { border-bottom: 1px solid currentColor; padding: 0 .18em .08em; }
    .math-denominator { padding: .08em .18em 0; }
    .math-root { display: inline-flex; align-items: flex-start; }
    .math-root-sign { font-size: 1.2em; line-height: .9; margin-right: .08em; }
    .math-text, .math-mathrm, .math-operatorname { font-family: -apple-system, BlinkMacSystemFont, sans-serif; font-style: normal; }
    .math-mathit { font-style: italic; }
    .math-mathbf { font-weight: 700; }
    .local-asset { display: block; margin: 18px 0; max-width: 100%; }
    .local-asset img, .local-asset video { display: block; max-width: 100%; height: auto; border-radius: 8px; }
    .local-asset-caption { display: block; margin-top: 7px; color: color-mix(in srgb, currentColor 68%, transparent); font-size: .9em; line-height: 1.45; }
    .repopress-source-jump { margin-left: .28em; color: currentColor; opacity: .32; text-decoration: none; font-size: .72em; }
    .repopress-source-jump:hover, .repopress-source-jump:focus { opacity: .9; text-decoration: underline; }
    """
  }
}
