import PublishingWorkbenchCore
import SwiftUI

struct KnowledgeRelatedChaptersSection: View {
  @StateObject private var state: KnowledgeRelatedChaptersFeatureFacade
  var showsHeader = true
  var maximumVisibleRecommendations: Int?

  init(
    knowledge: KnowledgeStore,
    showsHeader: Bool = true,
    maximumVisibleRecommendations: Int? = nil
  ) {
    _state = StateObject(
      wrappedValue: KnowledgeRelatedChaptersFeatureFacade(store: knowledge)
    )
    self.showsHeader = showsHeader
    self.maximumVisibleRecommendations = maximumVisibleRecommendations
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      if showsHeader {
        HStack {
          Label(sectionTitle, systemImage: "point.3.connected.trianglepath.dotted")
            .font(.workbenchHeadline)
          Spacer()
          if state.isLoading {
            ProgressView()
              .controlSize(.small)
              .accessibilityLabel("正在查找\(sectionTitle)")
          } else if !state.recommendations.isEmpty {
            Text("本地智能推荐")
              .font(.workbenchMetadata)
              .foregroundStyle(.workbenchSecondary)
          }
        }
      }

      if state.isLoading, state.recommendations.isEmpty {
        Text("正在结合语义、作者、标签和来源计算关联…")
          .font(.workbenchBody)
          .foregroundStyle(.workbenchSecondary)
      } else if state.recommendations.isEmpty {
        Text("暂时没有足够相关的其他内容。")
          .font(.workbenchBody)
          .foregroundStyle(.workbenchSecondary)
      } else {
        LazyVStack(spacing: 8) {
          ForEach(visibleRecommendations) { recommendation in
            Button {
              state.select(recommendation)
            } label: {
              relatedChapterRow(recommendation)
            }
            .buttonStyle(.plain)
            .accessibilityHint("打开并跳转到这个相关章节")
          }
        }
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("\(sectionTitle)推荐")
  }

  private var sectionTitle: String {
    state.usesChapterTerminology
      ? String(localized: "相关章节")
      : String(localized: "相关内容")
  }

  private var visibleRecommendations: [KnowledgeRelatedChapter] {
    guard let maximumVisibleRecommendations else {
      return state.recommendations
    }
    return Array(state.recommendations.prefix(maximumVisibleRecommendations))
  }

  private func relatedChapterRow(_ recommendation: KnowledgeRelatedChapter) -> some View {
    let excerpt = KnowledgeSearchPresentationService().presentation(
      for: KnowledgeSearchResult(
        document: recommendation.document,
        chunk: recommendation.chunk,
        score: recommendation.score
      ),
      query: "",
      maximumSnippetCharacters: 180
    ).snippet
    return VStack(alignment: .leading, spacing: 5) {
      HStack(alignment: .firstTextBaseline) {
        Text(recommendation.document.title)
          .font(.workbenchCardTitle)
          .workbenchTruncatedTitle(recommendation.document.title)
        Spacer()
        let location = recommendation.chunk.locator?.nilIfEmpty
          ?? recommendation.chunk.headingPath?.nilIfEmpty
          ?? String(localized: "正文片段")
        Text(location)
          .font(.workbenchMetadata)
          .foregroundStyle(.workbenchSecondary)
          .workbenchTruncatedIdentity(location)
      }
      Text(excerpt)
        .font(.workbenchSupporting)
        .foregroundStyle(.workbenchSecondary)
        .lineLimit(2)
        .multilineTextAlignment(.leading)
      LazyVGrid(
        columns: [GridItem(.adaptive(minimum: 72, maximum: 120), spacing: 5)],
        alignment: .leading,
        spacing: 5
      ) {
        ForEach(Array(recommendation.reasons.prefix(3)), id: \.self) { reason in
          Text(reason.localizedDisplayName)
            .font(.workbenchMetadata.weight(.medium))
            .lineLimit(1)
            .foregroundStyle(.workbenchSecondary)
            .padding(.horizontal, WorkbenchSpacing.icon)
            .padding(.vertical, 2)
            .background(Color.secondary.opacity(0.09), in: Capsule())
        }
      }
    }
    .padding(WorkbenchSpacing.card)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      WorkbenchBackgroundStyle.card, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
    )
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
    .accessibilityLabel(
      "\(recommendation.document.title)，"
        + recommendation.reasons.map(\.localizedDisplayName).joined(separator: "、")
        + "。\(excerpt)"
    )
  }
}
