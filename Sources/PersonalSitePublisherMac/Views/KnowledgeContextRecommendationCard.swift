import Foundation
import PublishingWorkbenchCore
import SwiftUI

/// A local-only bridge between the live Markdown buffer and the knowledge
/// library, presented in the article Inspector without opening the AI assistant.
struct KnowledgeContextRecommendationCard: View {
  let draft: ArticleDraft
  let store: WorkbenchStore
  @ObservedObject private var knowledge: KnowledgeStore
  @StateObject private var editorState: WorkbenchMarkdownEditorFeatureFacade
  @State private var recommendations: [KnowledgeSearchResult] = []
  @State private var isLoading = false
  @State private var errorMessage: String?

  init(draft: ArticleDraft, store: WorkbenchStore) {
    self.draft = draft
    self.store = store
    _knowledge = ObservedObject(wrappedValue: store.knowledge)
    _editorState = StateObject(
      wrappedValue: WorkbenchMarkdownEditorFeatureFacade(
        store: store,
        draftID: draft.id
      )
    )
  }

  private var liveBodyMarkdown: String {
    editorState.draftBodyEditorBuffer(for: draft.id).bodyMarkdown
  }

  private var liveSelectedRange: NSRange? {
    guard let selection = store.activeEditorSelection,
      selection.draftID == draft.id,
      selection.bodyUTF16Count == (liveBodyMarkdown as NSString).length
    else {
      return nil
    }

    let source = liveBodyMarkdown as NSString
    let range = selection.range
    guard range.location >= 0,
      range.length >= 0,
      range.location <= source.length,
      range.length <= source.length - range.location
    else {
      return nil
    }
    guard range.length == 0 || source.substring(with: range) == selection.selectedText else {
      return nil
    }
    return range
  }

  private var query: String {
    KnowledgeContextQueryService.query(
      for: draft,
      bodyMarkdown: liveBodyMarkdown,
      selectedRange: liveSelectedRange
    )
  }

  private var semanticRecommendationCount: Int {
    recommendations.filter { $0.signals.contains(.semantic) }.count
  }

  private var hasLocalSources: Bool {
    knowledge.documents.contains {
      !$0.isArchived && $0.allowsLocalSemanticIndex
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 9) {
      header

      if query.isEmpty {
        Text("写入标题、摘要或正文后，这里会自动关联本地资料。")
          .font(.workbenchSupporting)
          .foregroundStyle(.secondary)
      } else if isLoading && recommendations.isEmpty {
        HStack(spacing: 8) {
          ProgressView()
            .controlSize(.small)
          Text("正在查找相关网页、摘录和参考代码…")
            .font(.workbenchSupporting)
            .foregroundStyle(.secondary)
        }
      } else if recommendations.isEmpty {
        emptyState
      } else {
        ForEach(Array(recommendations.prefix(4))) { result in
          recommendationRow(result)
        }
        if recommendations.count > 4 {
          Text("还有 \(recommendations.count - 4) 个相关片段，可在资料库中查看全部结果。")
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
    .accessibilityIdentifier("knowledge-context-recommendation-card")
    .task(id: query) {
      await loadRecommendations(for: query)
    }
    .onChange(of: draft.id) { _, draftID in
      editorState.trackDraft(draftID)
    }
  }

  private var header: some View {
    HStack(alignment: .firstTextBaseline, spacing: 7) {
      Label("上下文知识建议", systemImage: "books.vertical")
        .font(.workbenchCardTitle)

      Spacer(minLength: 6)

      if isLoading {
        ProgressView()
          .controlSize(.small)
          .accessibilityLabel("正在更新资料库推荐")
      } else if semanticRecommendationCount > 0 {
        Text("本机语义 \(semanticRecommendationCount)")
          .font(.workbenchMetadata.weight(.medium))
          .foregroundStyle(.tint)
      } else {
        Text("自动")
          .font(.workbenchMetadata)
          .foregroundStyle(.secondary)
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("上下文知识建议")
  }

  private var emptyState: some View {
    VStack(alignment: .leading, spacing: 5) {
      if let errorMessage {
        Label("资料库推荐暂时不可用", systemImage: "exclamationmark.triangle")
          .font(.workbenchSupporting.weight(.medium))
        Text(errorMessage)
          .font(.workbenchMetadata)
          .foregroundStyle(.secondary)
      } else {
        Label(
          hasLocalSources ? "暂时没有足够相关的资料" : "还没有可用于本地关联的资料",
          systemImage: hasLocalSources ? "magnifyingglass" : "point.3.connected.trianglepath.dotted"
        )
        .font(.workbenchSupporting.weight(.medium))
        Text(
          hasLocalSources
            ? "继续写几句正文，或在资料库中导入网页、Markdown、PDF 和摘录。"
            : "在资料库中开启本地语义索引后，推荐会留在本机运行。"
        )
        .font(.workbenchMetadata)
        .foregroundStyle(.secondary)
      }
    }
  }

  private func recommendationRow(_ result: KnowledgeSearchResult) -> some View {
    let hit = KnowledgeSearchPresentationService().presentation(
      for: result,
      query: query,
      maximumSnippetCharacters: 210
    )
    return VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Image(systemName: result.document.kind.systemImage)
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)
        Text(result.document.title)
          .font(.workbenchItemTitle)
          .workbenchTruncatedIdentity(result.document.title)
        Spacer(minLength: 4)
        Text(sourceKindTitle(for: result))
          .font(.workbenchMetadata)
          .foregroundStyle(.secondary)
      }

      KnowledgeHighlightedText(text: hit.snippet, terms: hit.highlightTerms)
        .font(.workbenchSupporting)
        .foregroundStyle(.secondary)
        .lineLimit(3)

      HStack(spacing: 6) {
        if result.signals.contains(.semantic) {
          Text("语义")
            .font(.workbenchMetadata.weight(.medium))
            .foregroundStyle(WorkbenchTheme.info)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(WorkbenchTheme.info.opacity(0.1), in: Capsule())
        }
        if let location = hit.locationLabel {
          Text(location)
            .font(.workbenchMetadata)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        Spacer(minLength: 0)
      }

      HStack(spacing: 6) {
        Button {
          insert(result, style: .blockquote)
        } label: {
          Label("引用块", systemImage: "quote.opening")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)

        Button {
          insert(result, style: .footnote)
        } label: {
          Label("脚手架参考", systemImage: "text.badge.star")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)

        Image(systemName: "hand.draw")
          .font(.caption)
          .foregroundStyle(.secondary)
          .help("拖入正文将插入引用块")
          .accessibilityLabel("拖入正文插入引用块")
          .onDrag {
            KnowledgeArticleInsertionService.dragProvider(
              document: result.document,
              selectedResult: result,
              fallbackText: result.chunk.content
            )
          }
      }
    }
    .padding(9)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(WorkbenchBackgroundStyle.subtle, in: RoundedRectangle(cornerRadius: 9))
    .accessibilityElement(children: .combine)
    .accessibilityLabel(
      "\(result.document.title)，\(sourceKindTitle(for: result))。\(hit.snippet)"
    )
  }

  private func sourceKindTitle(for result: KnowledgeSearchResult) -> String {
    if result.chunk.content.contains("```")
      || result.chunk.content.contains("func ")
      || result.chunk.content.contains("import ")
    {
      return "参考代码"
    }
    if result.document.kind == .note {
      return "摘录笔记"
    }
    return result.document.kind.localizedDisplayName
  }

  private func insert(
    _ result: KnowledgeSearchResult,
    style: KnowledgeArticleInsertionStyle
  ) {
    _ = KnowledgeArticleInsertionService.insertCitation(
      document: result.document,
      selectedResult: result,
      fallbackText: result.chunk.content,
      style: style,
      into: store
    )
  }

  private func loadRecommendations(for query: String) async {
    recommendations = []
    errorMessage = nil
    guard !query.trimmedForPublishing.isEmpty else {
      isLoading = false
      return
    }

    isLoading = true
    do {
      try await Task.sleep(for: .milliseconds(420))
      let results = try await knowledge.contextRecommendations(query: query, limit: 6)
      guard !Task.isCancelled else { return }
      recommendations = results
      isLoading = false
    } catch is CancellationError {
      return
    } catch {
      guard !Task.isCancelled else { return }
      errorMessage = error.localizedDescription
      isLoading = false
    }
  }
}
