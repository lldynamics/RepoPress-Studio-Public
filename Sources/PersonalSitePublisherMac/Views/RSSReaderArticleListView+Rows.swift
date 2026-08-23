import Foundation
import SwiftUI
import PublishingWorkbenchCore

/// RSS 文章列表的骨架屏占位：模拟文章行，列表在后台准备时显示，
/// 避免空白或转圈带来的跳动感。
struct RSSArticleListSkeleton: View {
  @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
  @State private var isPulsing = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(0..<8, id: \.self) { _ in
        skeletonRow
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .opacity(accessibilityReduceMotion ? 1 : (isPulsing ? 0.55 : 1))
    .animation(accessibilityReduceMotion ? nil : WorkbenchMotion.ambientPulse, value: isPulsing)
    .onAppear { isPulsing = !accessibilityReduceMotion }
    .onChange(of: accessibilityReduceMotion) { _, shouldReduceMotion in
      isPulsing = !shouldReduceMotion
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("正在准备文章列表")
  }

  private var skeletonRow: some View {
    HStack(alignment: .top, spacing: 10) {
      RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
        .fill(Color.primary.opacity(0.06))
        .frame(width: 36, height: 36)

      VStack(alignment: .leading, spacing: 6) {
        RoundedRectangle(cornerRadius: 3)
          .fill(Color.primary.opacity(0.08))
          .frame(height: 12)
          .frame(maxWidth: 260)
        RoundedRectangle(cornerRadius: 3)
          .fill(Color.primary.opacity(0.05))
          .frame(height: 10)
          .frame(maxWidth: 190)
        RoundedRectangle(cornerRadius: 3)
          .fill(Color.primary.opacity(0.04))
          .frame(height: 10)
          .frame(maxWidth: 150)
      }

      Spacer(minLength: 0)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
  }
}

/// 刷新期间只保留轻量的顶部进度线，避免把正文列表推下去。
struct RSSArticleRefreshProgressLine: View {
  @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
  @State private var isAnimating = false

  var body: some View {
    GeometryReader { geometry in
      let segmentWidth = max(48, geometry.size.width * 0.24)
      ZStack(alignment: .leading) {
        Rectangle()
          .fill(Color.accentColor.opacity(0.14))
        Rectangle()
          .fill(Color.accentColor.opacity(0.9))
          .frame(width: segmentWidth)
          .offset(
            x: accessibilityReduceMotion
              ? 0
              : (isAnimating ? geometry.size.width : -segmentWidth)
          )
      }
    }
    .frame(height: 2)
    .clipped()
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("正在刷新文章列表")
    .accessibilityIdentifier("rss-article-refresh-progress")
    .onAppear {
      isAnimating = !accessibilityReduceMotion
    }
    .onDisappear {
      isAnimating = false
    }
    .animation(
      accessibilityReduceMotion
        ? nil
        : .linear(duration: 1.15).repeatForever(autoreverses: false),
      value: isAnimating
    )
    .onChange(of: accessibilityReduceMotion) { _, shouldReduceMotion in
      isAnimating = !shouldReduceMotion
    }
  }
}


#if DEBUG
  #Preview("RSS Article List Skeleton") {
    RSSArticleListSkeleton()
      .frame(width: 360, height: 560)
      .background(.background)
  }
#endif

struct RSSArticleRow: View {
  let article: RSSArticleHeader
  let feed: RSSFeed?
  let summary: String
  let readingProgress: Double
  let isBatchSelectionMode: Bool
  let isBatchSelected: Bool
  let onToggleBatchSelection: () -> Void
  let onToggleRead: () -> Void
  let onToggleStarred: () -> Void
  let onOpenOriginal: () -> Void
  @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
  @State private var isHovering = false

  var body: some View {
    let relativeDate = (article.publishedAt ?? article.fetchedAt).formatted(
      .relative(presentation: .named, unitsStyle: .abbreviated)
    )
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .top, spacing: 8) {
        if isBatchSelectionMode {
          Toggle(
            "选择文章",
            isOn: Binding(
              get: { isBatchSelected },
              set: { _ in onToggleBatchSelection() }
            )
          )
          .toggleStyle(.checkbox)
          .labelsHidden()
          .accessibilityLabel("选择文章：\(article.title)")
          .accessibilityValue(isBatchSelected ? "已选择" : "未选择")
        }
        Circle()
          .fill(article.isRead ? Color.clear : Color.accentColor)
          .frame(width: 7, height: 7)
          .scaleEffect(
            !accessibilityReduceMotion && isHovering && !article.isRead ? 1.15 : 1
          )
          .animation(
            accessibilityReduceMotion ? nil : .easeInOut(duration: 0.16),
            value: isHovering
          )
          .overlay {
            Circle()
              .stroke(article.isRead ? Color.secondary.opacity(0.45) : Color.clear, lineWidth: 1)
          }
          .padding(.top, 6)
          .accessibilityHidden(true)

        VStack(alignment: .leading, spacing: 5) {
          Text(article.title)
            .font(article.isRead ? .body : .body.weight(.semibold))
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
          HStack(spacing: 6) {
            if let feed {
              Text(feed.displayTitle)
            }
            if let author = article.author?.trimmedForPublishing.nilIfEmpty {
              Text(author)
            }
            Text(relativeDate)
            if article.isStarred {
              Image(systemName: "star.fill")
                .foregroundStyle(.yellow)
                .accessibilityHidden(true)
            }
          }
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .fixedSize(horizontal: false, vertical: true)

          if summary.isEmpty {
            Text("暂无摘要")
              .font(.caption)
              .foregroundStyle(.tertiary)
              .lineLimit(1)
          } else {
            Text(summary)
              .font(.callout)
              .foregroundStyle(.secondary)
              .lineLimit(2)
              .truncationMode(.tail)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(article.title)
        .accessibilityValue(accessibilityValue(relativeDate: relativeDate))

        if let coverURL = article.coverURL {
          RSSArticleCoverThumbnail(articleID: article.id, url: coverURL)
        }
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .accessibilityElement(children: .contain)

      if normalizedReadingProgress > 0 {
        GeometryReader { geometry in
          ZStack(alignment: .leading) {
            Rectangle()
              .fill(Color.accentColor.opacity(0.12))
            Rectangle()
              .fill(Color.accentColor)
              .frame(width: geometry.size.width * normalizedReadingProgress)
          }
        }
        .frame(height: 2)
        .accessibilityHidden(true)
      }
    }
    .overlay(alignment: .topTrailing) {
      if !isBatchSelectionMode {
        articleActionButtons
          .padding(.top, 6)
          .padding(.trailing, 8)
          .opacity(isHovering ? 1 : 0.72)
      }
    }
    .background(isHovering ? Color.primary.opacity(0.04) : Color.clear)
    .onHover { isHovering = $0 }
    .accessibilityIdentifier("rss-article-row-content-\(article.id)")
    .accessibilityElement(children: .contain)
  }

  private var articleActionButtons: some View {
    HStack(spacing: 3) {
      Button(action: onToggleRead) {
        Image(systemName: article.isRead ? "envelope.badge" : "checkmark.circle")
      }
      .buttonStyle(.borderless)
      .controlSize(.small)
      .help(article.isRead ? "标为未读" : "标为已读")
      .accessibilityLabel(article.isRead ? "标为未读" : "标为已读")

      Button(action: onToggleStarred) {
        Image(systemName: article.isStarred ? "star.slash" : "star")
      }
      .buttonStyle(.borderless)
      .controlSize(.small)
      .help(article.isStarred ? "移出稍后阅读" : "加入稍后阅读")
      .accessibilityLabel(article.isStarred ? "移出稍后阅读" : "加入稍后阅读")

      if article.link != nil {
        Button(action: onOpenOriginal) {
          Image(systemName: "safari")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .help("打开原文")
        .accessibilityLabel("打开原文")
      }
    }
    .padding(4)
    .background(.regularMaterial, in: Capsule())
    .accessibilityElement(children: .contain)
    .accessibilityLabel("文章操作")
  }

  private func accessibilityValue(relativeDate: String) -> String {
    var components = [
      feed?.displayTitle ?? "RSS",
      relativeDate,
      article.isRead ? String(localized: "已读") : String(localized: "未读"),
    ]
    if let author = article.author?.trimmedForPublishing.nilIfEmpty {
      components.append(String(localized: "作者 \(author)"))
    }
    if article.isStarred { components.append(String(localized: "稍后阅读")) }
    if !article.tags.isEmpty {
      components.append(String(localized: "标签 \(article.tags.joined(separator: "、"))"))
    }
    if summary.isEmpty {
      components.append(String(localized: "暂无摘要"))
    } else {
      components.append(String(localized: "摘要 \(String(summary.prefix(240)))"))
    }
    components.append(String(localized: "已读 \(readingProgressPercentage)%"))
    return components.joined(separator: "，")
  }

  private var normalizedReadingProgress: Double {
    min(max(readingProgress, 0), 1)
  }

  private var readingProgressPercentage: Int {
    Int((normalizedReadingProgress * 100).rounded())
  }

}
