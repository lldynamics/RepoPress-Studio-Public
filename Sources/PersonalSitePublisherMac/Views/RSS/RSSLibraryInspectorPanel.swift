import PublishingWorkbenchCore
import SwiftUI

private struct RSSLibraryInspectorEntry: Identifiable {
  let id: String
  let article: RSSArticleHeader
  let highlight: RSSArticleHighlight?

  var date: Date {
    highlight?.updatedAt ?? article.publishedAt ?? article.fetchedAt
  }

  var excerpt: String {
    let value = highlight?.text ?? article.readableSummary
    return String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(280))
  }

  var isStarred: Bool { article.isStarred }

  var kindTitle: String {
    highlight == nil ? String(localized: "稍后阅读") : String(localized: "RSS 高亮")
  }
}

struct RSSLibraryInspectorPanel: View {
  @ObservedObject var rssStore: RSSReaderStore
  let workbenchStore: WorkbenchStore
  @State private var dragStyle: KnowledgeArticleInsertionStyle = .blockquote
  @State private var loadingEntryIDs: Set<String> = []
  @State private var errorMessage: String?

  private var entries: [RSSLibraryInspectorEntry] {
    let articlesByID = Dictionary(
      rssStore.articleHeaders.map { ($0.id, $0) },
      uniquingKeysWith: { first, _ in first }
    )
    let highlightedArticleIDs = Set(rssStore.highlights.map(\RSSArticleHighlight.articleID))
    let highlights = rssStore.highlights.compactMap { highlight -> RSSLibraryInspectorEntry? in
      guard let article = articlesByID[highlight.articleID] else { return nil }
      return RSSLibraryInspectorEntry(
        id: "highlight-\(highlight.id.uuidString)",
        article: article,
        highlight: highlight
      )
    }
    let starredArticles = rssStore.articleHeaders
      .filter { $0.isStarred && !highlightedArticleIDs.contains($0.id) }
      .map { article in
        RSSLibraryInspectorEntry(
          id: "article-\(article.id)",
          article: article,
          highlight: nil
        )
      }

    return (highlights + starredArticles).sorted { lhs, rhs in
      if lhs.date != rhs.date { return lhs.date > rhs.date }
      return lhs.id < rhs.id
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      header

      if entries.isEmpty {
        Label(
          "RSS 资料库中还没有稍后阅读文章或高亮。",
          systemImage: "tray"
        )
        .font(.workbenchSupporting)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      } else {
        Picker("拖拽格式", selection: $dragStyle) {
          Text("引用块").tag(KnowledgeArticleInsertionStyle.blockquote)
          Text("脚注").tag(KnowledgeArticleInsertionStyle.footnote)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityLabel("拖拽格式")
        .accessibilityValue(dragStyle == .blockquote ? "引用块" : "脚注")

        VStack(alignment: .leading, spacing: 8) {
          ForEach(entries.prefix(30)) { entry in
            entryRow(entry)
          }
        }

        if entries.count > 30 {
          Text("仅显示最近 30 条 RSS 稍后阅读文章与高亮。")
            .font(.workbenchMetadata)
            .foregroundStyle(.secondary)
        }
      }
    }
    .padding(12)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
    .overlay {
      RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
        .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5))
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("rss-library-inspector-panel")
    .alert("RSS 插入失败", isPresented: Binding(
      get: { errorMessage != nil },
      set: { if !$0 { errorMessage = nil } }
    )) {
      Button("确定") { errorMessage = nil }
    } message: {
      Text(errorMessage ?? "")
    }
  }

  private var header: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Label("RSS 稍后阅读与高亮", systemImage: "dot.radiowaves.left.and.right")
        .font(.workbenchCardTitle)
      Spacer(minLength: 6)
      if !entries.isEmpty {
        Text("\(entries.count)")
          .font(.workbenchMetadata.monospacedDigit())
          .foregroundStyle(.secondary)
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("RSS 稍后阅读与高亮")
  }

  private func entryRow(_ entry: RSSLibraryInspectorEntry) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Button {
        loadAndInsert(entry, style: .blockquote)
      } label: {
        HStack(alignment: .top, spacing: 8) {
          Image(systemName: entry.highlight == nil ? "star.fill" : "highlighter")
            .foregroundStyle(
              entry.highlight == nil
                ? WorkbenchTheme.warning
                : WorkbenchTheme.navigationSelection
            )
            .frame(width: 16)

          VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
              Text(entry.kindTitle)
                .font(.workbenchMetadata.weight(.medium))
                .foregroundStyle(.secondary)
              if entry.isStarred {
                Image(systemName: "star.fill")
                  .font(.workbenchMetadata)
                  .foregroundStyle(WorkbenchTheme.warning)
                  .accessibilityLabel("已加入稍后阅读")
              }
            }
            Text(entry.article.title)
              .font(.workbenchItemTitle)
              .workbenchTruncatedIdentity(entry.article.title)
            Text(entry.excerpt)
              .font(.workbenchSupporting)
              .foregroundStyle(.secondary)
              .lineLimit(4)
              .fixedSize(horizontal: false, vertical: true)
          }
          Spacer(minLength: 0)
        }
      }
      .buttonStyle(.plain)
      .disabled(loadingEntryIDs.contains(entry.id))
      .help("点击高亮文本插入引用块")
      .accessibilityLabel("\(entry.article.title)，\(entry.kindTitle)：\(entry.excerpt)")

      HStack(spacing: 6) {
        Button("引用块", systemImage: "quote.opening") {
          loadAndInsert(entry, style: .blockquote)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(loadingEntryIDs.contains(entry.id))

        Button("脚注", systemImage: "text.badge.star") {
          loadAndInsert(entry, style: .footnote)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(loadingEntryIDs.contains(entry.id))

        Spacer(minLength: 0)

        if loadingEntryIDs.contains(entry.id) {
          ProgressView()
            .controlSize(.small)
            .accessibilityLabel("正在读取文章正文")
        }

        Image(systemName: "hand.draw")
          .font(.caption)
          .foregroundStyle(.secondary)
          .help("拖拽到正文")
          .accessibilityLabel("拖拽到正文")
          .onDrag {
            KnowledgeArticleInsertionService.rssDragProvider(
              article: RSSArticle(header: entry.article),
              highlight: entry.highlight,
              style: dragStyle
            )
          }
      }
    }
    .padding(9)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(WorkbenchBackgroundStyle.card, in: RoundedRectangle(cornerRadius: 9))
  }

  private func loadAndInsert(
    _ entry: RSSLibraryInspectorEntry,
    style: KnowledgeArticleInsertionStyle
  ) {
    guard loadingEntryIDs.insert(entry.id).inserted else { return }
    Task { @MainActor in
      defer { loadingEntryIDs.remove(entry.id) }
      do {
        guard let article = try await rssStore.loadArticle(id: entry.article.id) else {
          errorMessage = String(localized: "找不到这篇文章的本机正文。")
          return
        }
        _ = KnowledgeArticleInsertionService.insertRSSContent(
          article: article,
          highlight: entry.highlight,
          style: style,
          into: workbenchStore
        )
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }
}
