import PublishingWorkbenchCore
import SwiftUI

/// RSS has its own reading-oriented native toolbar items. Each button stays a
/// direct toolbar child at the call site so AppKit preserves its AX target.
struct WorkspaceRSSReadingToolbar: View {
  @ObservedObject private var rssStore: RSSReaderStore
  @ObservedObject private var commandRouter: WorkspaceSceneCommandRouter
  let isEnabled: Bool

  init(
    rssStore: RSSReaderStore,
    commandRouter: WorkspaceSceneCommandRouter,
    isEnabled: Bool
  ) {
    _rssStore = ObservedObject(wrappedValue: rssStore)
    _commandRouter = ObservedObject(wrappedValue: commandRouter)
    self.isEnabled = isEnabled
  }

  var body: some View {
    Group {
      WorkspaceToolbarActionButton(
        title: String(localized: "刷新"),
        systemImage: rssStore.refreshingFeedIDs.isEmpty
          ? "arrow.clockwise" : "arrow.triangle.2.circlepath.circle.fill",
        accessibilityIdentifier: "workspace-rss-refresh",
        isActive: !rssStore.refreshingFeedIDs.isEmpty,
        isEnabled: isEnabled && rssStore.refreshingFeedIDs.isEmpty,
        help: String(localized: "刷新 RSS 订阅")
      ) {
        Task { await rssStore.refreshAll() }
      }

      WorkspaceToolbarActionButton(
        title: String(localized: "上一篇文章"),
        systemImage: "chevron.up",
        accessibilityIdentifier: "workspace-rss-previous-article",
        isEnabled: isEnabled
          && (commandRouter.rssReaderCommandActions?.canNavigatePrevious ?? false),
        help: String(localized: "阅读上一篇文章（Control-Command-左箭头）")
      ) {
        commandRouter.rssReaderCommandActions?.navigatePrevious()
      }

      WorkspaceToolbarActionButton(
        title: String(localized: "下一篇文章"),
        systemImage: "chevron.down",
        accessibilityIdentifier: "workspace-rss-next-article",
        isEnabled: isEnabled && (commandRouter.rssReaderCommandActions?.canNavigateNext ?? false),
        help: String(localized: "阅读下一篇文章（Control-Command-右箭头）")
      ) {
        commandRouter.rssReaderCommandActions?.navigateNext()
      }

      WorkspaceToolbarActionButton(
        title: String(localized: "切换已读状态"),
        systemImage: "checkmark.circle",
        accessibilityIdentifier: "workspace-rss-toggle-read",
        isEnabled: isEnabled && (commandRouter.rssReaderCommandActions?.canActOnArticle ?? false),
        help: String(localized: "切换当前文章的已读状态（Control-Command-U）")
      ) {
        commandRouter.rssReaderCommandActions?.toggleRead()
      }
    }
  }
}
