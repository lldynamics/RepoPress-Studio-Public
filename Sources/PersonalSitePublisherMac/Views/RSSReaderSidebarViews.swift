import AppKit
import PublishingWorkbenchCore
import SwiftUI

struct RSSReaderWorkspaceSidebar: View {
  @ObservedObject var store: RSSReaderStore
  @ObservedObject var presentation: RSSReaderPresentationState
  @State private var feedPendingDeletion: RSSFeed?
  @State private var feedPendingAddressEdit: RSSFeed?

  var body: some View {
    RSSFeedSidebar(
      store: store,
      counts: presentation.sidebarCounts(in: store),
      selectedScope: $presentation.selectedScope,
      isAddSubscriptionPresented: $presentation.isAddSubscriptionPresented,
      removeFeed: { feedPendingDeletion = $0 },
      editFeedAddress: { feedPendingAddressEdit = $0 }
    )
    .sheet(item: $feedPendingAddressEdit) { feed in
      RSSEditFeedURLSheet(feed: feed) { newURL in
        try store.updateFeedURL(feedID: feed.id, newURL: newURL)
        Task { await store.refresh(feedID: feed.id, force: true) }
      }
    }
    .confirmationDialog(
      "删除订阅？",
      isPresented: deletionConfirmationBinding,
      titleVisibility: .visible
    ) {
      Button("删除订阅与本地缓存", role: .destructive) {
        guard let pendingFeed = feedPendingDeletion else { return }
        if case let .feed(feedID) = presentation.selectedScope, feedID == pendingFeed.id {
          presentation.selectedScope = .all
          presentation.selectedArticleID = nil
        }
        store.removeFeed(id: pendingFeed.id)
        feedPendingDeletion = nil
      }
      Button("取消", role: .cancel) {
        feedPendingDeletion = nil
      }
    } message: {
      Text(
        "将删除“\(feedPendingDeletion?.displayTitle ?? "该订阅")”及本机缓存文章（包括已加入稍后阅读的文章）。删除后可在底部立即撤销。"
      )
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("rss-reader-sidebar")
  }

  private var deletionConfirmationBinding: Binding<Bool> {
    Binding(
      get: { feedPendingDeletion != nil },
      set: { isPresented in
        if !isPresented { feedPendingDeletion = nil }
      }
    )
  }
}
struct RSSFeedSidebar: View {
  @ObservedObject var store: RSSReaderStore
  let counts: RSSFeedSidebarCounts
  @Binding var selectedScope: RSSArticleScope?
  @Binding var isAddSubscriptionPresented: Bool
  @State private var isAttentionSectionExpanded = false
  let removeFeed: (RSSFeed) -> Void
  let editFeedAddress: (RSSFeed) -> Void

  var body: some View {
    let feedGroups = RSSFeedSidebarFeedGroups(feeds: store.feeds)
    let now = Date()
    let failedFeedCount = store.feeds.filter { feed in
      switch feed.healthStatus(now: now) {
      case .failing, .backingOff:
        true
      case .never, .healthy:
        false
      }
    }.count

    VStack(spacing: 0) {
      WorkspaceContextListHeader(title: "订阅") {
        Text("\(store.feeds.count) 个订阅 · \(counts.unreadCount) 篇未读\n已抓取文章默认保存在本机")
      } actions: {
        Button {
          isAddSubscriptionPresented = true
        } label: {
          WorkspaceSidebarHeaderIcon("plus")
        }
        .workbenchProminentActionStyle()
        .help("添加 RSS 或 Atom 订阅")
        .accessibilityLabel("添加 RSS 或 Atom 订阅")
        .accessibilityIdentifier("rss-add-subscription")

        if failedFeedCount > 0 {
          Button {
            Task { await store.refreshFailedFeeds() }
          } label: {
            WorkspaceSidebarHeaderIcon("arrow.triangle.2.circlepath")
          }
          .disabled(store.isRefreshing)
          .help("重试全部失败订阅（\(failedFeedCount)）")
          .accessibilityLabel("重试全部失败订阅（\(failedFeedCount)）")
          .accessibilityIdentifier("rss-retry-failed-feeds")
        }

        Menu {
          Button {
            Task { await store.refreshAll() }
          } label: {
            Label(store.isRefreshing ? "正在刷新…" : "刷新全部", systemImage: "arrow.clockwise")
          }
          .disabled(store.isRefreshing || store.feeds.isEmpty)
          .keyboardShortcut("r", modifiers: [.command])
          Button {
            Task { await store.refreshFailedFeeds() }
          } label: {
            Label("重试失败订阅（\(failedFeedCount)）", systemImage: "arrow.triangle.2.circlepath")
          }
          .disabled(store.isRefreshing || failedFeedCount == 0)
        } label: {
          WorkspaceSidebarHeaderIcon("ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help("刷新订阅")
        .accessibilityLabel("RSS 订阅管理")
        .accessibilityIdentifier("rss-subscription-management")
      }
      .padding(.horizontal, WorkspaceSidebarMetrics.horizontalPadding)
      .padding(.vertical, WorkspaceSidebarMetrics.headerVerticalPadding)

      Divider()

      List(selection: $selectedScope) {
        Section("阅读列表") {
          scopeRow(
            title: "全部文章",
            systemImage: "tray.full",
            scope: .all,
            count: store.articleHeaders.count
          )
          scopeRow(
            title: "未读",
            systemImage: "circle",
            scope: .unread,
            count: counts.unreadCount
          )
          scopeRow(
            title: "稍后阅读",
            systemImage: "star",
            scope: .starred,
            count: counts.starredCount
          )
        }

        if !feedGroups.needsAttention.isEmpty {
          DisclosureGroup(isExpanded: $isAttentionSectionExpanded) {
            ForEach(feedGroups.needsAttention) { feed in
              feedRow(
                feed,
                unreadCount: counts.unreadCount(for: feed.id),
                showsRecoveryAction: true
              )
            }
          } label: {
            HStack(spacing: 8) {
              Label("需要处理", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(WorkbenchTheme.risk)
              Spacer(minLength: 4)
              Text(feedGroups.needsAttention.count.formatted())
                .font(.caption.monospacedDigit())
                .foregroundStyle(WorkbenchTheme.risk)
                .accessibilityHidden(true)
            }
          }
          .accessibilityLabel("需要处理")
          .accessibilityValue(
            String(
              format: String(localized: "%lld 个订阅"),
              Int64(feedGroups.needsAttention.count)
            )
          )
        }

        Section("我的订阅") {
          if store.feeds.isEmpty {
            Text("还没有订阅")
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          } else {
            ForEach(feedGroups.regular) { feed in
              feedRow(
                feed,
                unreadCount: counts.unreadCount(for: feed.id),
                showsRecoveryAction: false
              )
            }
          }
        }
      }
      .listStyle(.sidebar)
      .accessibilityLabel("RSS 订阅和阅读范围")
    }
  }

  private func feedRow(
    _ feed: RSSFeed,
    unreadCount: Int,
    showsRecoveryAction: Bool
  ) -> some View {
    let isRefreshing = store.refreshingFeedIDs.contains(feed.id)
    let now = Date()
    let health = feed.healthStatus(now: now)
    let status = feedSecondaryStatus(feed, now: now)
    return HStack(alignment: .top, spacing: 8) {
      VStack(alignment: .leading, spacing: 3) {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          Image(systemName: health.systemImage)
            .foregroundStyle(health.tint)
            .accessibilityHidden(true)
          Text(feed.displayTitle)
            .lineLimit(2)
          Spacer(minLength: 4)
          if unreadCount > 0 {
            Text(unreadCount.formatted())
              .font(.caption.monospacedDigit())
              .foregroundStyle(.secondary)
              .accessibilityHidden(true)
          }
        }
        Text(status.text)
          .font(.workbenchMetadata)
          .foregroundStyle(status.isFailure ? WorkbenchTheme.risk : Color.secondary)
          .lineLimit(2)
          .help(status.text)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityElement(children: .combine)
      .accessibilityLabel(feed.displayTitle)
      .accessibilityValue(
        RSSArticlePresentationSupport.feedAccessibilityValue(feed, unreadCount: unreadCount)
      )
    }
    .tag(RSSArticleScope.feed(feed.id))
    .contextMenu {
      Button("刷新此订阅") {
        Task { await store.refresh(feedID: feed.id, force: true) }
      }
      .disabled(isRefreshing)
      Button("复制订阅地址") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(feed.url.absoluteString, forType: .string)
      }
      Button("修改订阅地址") {
        editFeedAddress(feed)
      }
      Divider()
      Button("删除订阅", role: .destructive) {
        removeFeed(feed)
      }
    }
  }

  private func feedSecondaryStatus(
    _ feed: RSSFeed,
    now: Date
  ) -> (text: String, isFailure: Bool) {
    if let issueMessage = feed.lastIssue?.userMessage ?? feed.lastError {
      let details = [
        issueMessage,
        retryDescription(for: feed, now: now),
        lastSuccessfulRefreshDescription(for: feed)
      ].compactMap { $0 }
      return (details.joined(separator: " · "), true)
    }
    if let successDescription = lastSuccessfulRefreshDescription(for: feed) {
      return (successDescription, false)
    }
    return ("尚未成功刷新", false)
  }

  private func lastSuccessfulRefreshDescription(for feed: RSSFeed) -> String? {
    guard let lastUpdatedAt = feed.lastUpdatedAt else { return nil }
    return "上次成功刷新 \(lastUpdatedAt.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))"
  }

  private func retryDescription(for feed: RSSFeed, now: Date) -> String? {
    if let issue = feed.lastIssue {
      switch issue.retryStrategy {
      case .requiresAction:
        return String(localized: "需要修改地址、证书或访问权限后再重试。")
      case .manual:
        return String(localized: "不会自动重试，可手动重试。")
      case .none:
        return nil
      case .automatic, .afterDate:
        break
      }
    }
    guard let retryAt = feed.nextRetryAt ?? feed.lastIssue?.retryAt else { return nil }
    if retryAt <= now {
      return String(localized: "已到重试时间，正在等待后台刷新。")
    }
    let exact = retryAt.formatted(date: .abbreviated, time: .shortened)
    return String(localized: "自动重试：\(exact)")
  }

  private func scopeRow(
    title: String,
    systemImage: String,
    scope: RSSArticleScope,
    count: Int
  ) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Label(title, systemImage: systemImage)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 4)
      Text(count.formatted())
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .accessibilityLabel("\(count) 篇")
    }
    .tag(scope)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(title)
    .accessibilityValue("\(count) 篇")
  }
}

struct RSSFeedSidebarFeedGroups: Equatable {
  let needsAttention: [RSSFeed]
  let regular: [RSSFeed]

  init(feeds: [RSSFeed], now: Date = Date()) {
    var needsAttention: [RSSFeed] = []
    var regular: [RSSFeed] = []
    for feed in feeds {
      if RSSArticlePresentationSupport.feedNeedsAttention(feed, now: now) {
        needsAttention.append(feed)
      } else {
        regular.append(feed)
      }
    }
    self.needsAttention = needsAttention
    self.regular = regular
  }
}

struct RSSFeedSidebarCounts: Equatable {
  let unreadCount: Int
  let starredCount: Int
  private let unreadCountByFeedID: [UUID: Int]

  init(articles: [RSSArticleHeader]) {
    var unreadCount = 0
    var starredCount = 0
    var unreadCountByFeedID: [UUID: Int] = [:]

    for article in articles {
      if article.isStarred {
        starredCount += 1
      }
      if !article.isRead {
        unreadCount += 1
        unreadCountByFeedID[article.feedID, default: 0] += 1
      }
    }

    self.unreadCount = unreadCount
    self.starredCount = starredCount
    self.unreadCountByFeedID = unreadCountByFeedID
  }

  func unreadCount(for feedID: UUID) -> Int {
    unreadCountByFeedID[feedID, default: 0]
  }
}

struct RSSFeedLookup {
  private let feedsByID: [UUID: RSSFeed]

  init(feeds: [RSSFeed]) {
    feedsByID = Dictionary(
      feeds.map { ($0.id, $0) },
      uniquingKeysWith: { existing, _ in existing }
    )
  }

  subscript(feedID: UUID) -> RSSFeed? {
    feedsByID[feedID]
  }
}

private extension RSSFeedHealthStatus {
  var systemImage: String {
    switch self {
    case .never: return "circle.dashed"
    case .healthy: return "checkmark.circle.fill"
    case .failing: return "exclamationmark.triangle.fill"
    case .backingOff: return "clock.arrow.circlepath"
    }
  }

  var tint: Color {
    switch self {
    case .never: return .secondary
    case .healthy: return WorkbenchTheme.success
    case .failing: return WorkbenchTheme.risk
    case .backingOff: return WorkbenchTheme.warning
    }
  }
}
