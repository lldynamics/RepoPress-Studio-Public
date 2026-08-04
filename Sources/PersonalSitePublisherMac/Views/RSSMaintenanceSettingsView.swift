import PublishingWorkbenchCore
import SwiftUI

@MainActor
struct RSSMaintenanceSettingsView: View {
  @ObservedObject var store: RSSReaderStore

  @AppStorage(RSSReaderStore.automaticPruningDefaultsKey)
  private var automaticPruningEnabled = false
  @AppStorage(RSSReaderStore.retentionDaysDefaultsKey)
  private var retentionDays = RSSReaderStore.defaultRetentionDays
  @State private var isPruneConfirmationPresented = false
  @State private var pruneFeedback: String?
  @State private var pruneFeedbackIsError = false

  var body: some View {
    Form {
      Section(String(localized: "本地 RSS 缓存")) {
        LabeledContent("订阅数量", value: store.feeds.count.formatted())
        LabeledContent("本机文章", value: store.articleHeaders.count.formatted())
        LabeledContent("已归档媒体", value: store.mediaAssets.count.formatted())
        Text("Feed 正文、网页全文快照和媒体归档是三项独立的本地保存范围；关闭某一项不会删除已经保存的本地副本。")
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      Section(String(localized: "离线保存范围")) {
        settingsToggle(
          title: String(localized: "Feed 正文"),
          detail: String(localized: "只保存 RSS 或 Atom 实际返回的摘要和正文 HTML；不会抓取原网页缺失的全文。"),
          isOn: Binding(
            get: { store.feedBodyOfflineCacheEnabled },
            set: { store.updateFeedBodyOfflineCacheSettings(enabled: $0) }
          ),
          accessibilityIdentifier: "rss-feed-body-offline-cache"
        )

        settingsToggle(
          title: String(localized: "网页全文快照"),
          detail: String(localized: "开启后按文章链接抓取受大小限制的网页 HTML，并在 Feed 正文缺失时作为离线阅读回退；不会补齐原网页没有公开的内容。"),
          isOn: Binding(
            get: { store.webPageSnapshotEnabled },
            set: { store.updateWebPageSnapshotSettings(enabled: $0) }
          ),
          accessibilityIdentifier: "rss-web-page-snapshot"
        )

        settingsToggle(
          title: String(localized: "全部媒体"),
          detail: String(localized: "开启后自动保存文章中可识别的图片、视频、音频和带下载标记的附件；每项受数量、大小和类型限制，默认关闭。收藏或添加高亮的文章仍会按原有规则归档媒体。"),
          isOn: Binding(
            get: { store.automaticMediaCacheEnabled },
            set: { store.updateAutomaticMediaCacheSettings(enabled: $0) }
          ),
          accessibilityIdentifier: "rss-automatic-media-cache"
        )
      }

      Section(String(localized: "网络安全")) {
        settingsToggle(
          title: String(localized: "允许访问内网 RSS"),
          detail: String(localized: "默认只允许访问公网地址，并会在每次重定向时重新检查 DNS/IP。只有订阅明确位于局域网或本机时才开启此选项。"),
          isOn: Binding(
            get: { store.privateNetworkAccessEnabled },
            set: { store.updatePrivateNetworkAccessSettings(enabled: $0) }
          ),
          accessibilityIdentifier: "rss-private-network-access"
        )
      }

      Section(String(localized: "自动清理历史文章")) {
        Toggle("启用自动清理", isOn: $automaticPruningEnabled)
          .onChange(of: automaticPruningEnabled) { _, enabled in
            store.updateRetentionSettings(enabled: enabled, days: retentionDays)
          }
          .accessibilityIdentifier("rss-automatic-pruning")

        Picker("保留最近", selection: $retentionDays) {
          ForEach([30, 60, 90, 180, 365, 730], id: \.self) { days in
            Text("最近 \(days) 天").tag(days)
          }
        }
        .onChange(of: retentionDays) { _, days in
          store.updateRetentionSettings(enabled: automaticPruningEnabled, days: days)
        }
        .disabled(!automaticPruningEnabled)
        .accessibilityIdentifier("rss-retention-days")

        Text("只会清理超过保留期限、已读、未加入稍后阅读且没有高亮的文章；稍后阅读文章、批注和已归档媒体不会被误删。")
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)

        HStack {
          Button("立即清理", systemImage: "trash", role: .destructive) {
            isPruneConfirmationPresented = true
          }
          .buttonStyle(.bordered)

          if let pruneFeedback {
            Label(
              pruneFeedback,
              systemImage: pruneFeedbackIsError ? "exclamationmark.triangle" : "checkmark.circle"
            )
            .font(.caption)
            .foregroundStyle(pruneFeedbackIsError ? WorkbenchTheme.warning : Color.secondary)
          }
        }
      }
    }
    .formStyle(.grouped)
    .scrollIndicators(.hidden)
    .padding(WorkbenchSpacing.content)
    .confirmationDialog(
      "清理 RSS 历史文章？",
      isPresented: $isPruneConfirmationPresented,
      titleVisibility: .visible
    ) {
      Button("清理 \(retentionDays) 天前的历史文章", role: .destructive) {
        pruneHistory()
      }
      Button("取消", role: .cancel) {}
    } message: {
      Text("只会删除已读、未加入稍后阅读且没有高亮的文章；此操作无法撤销。")
    }
    .accessibilityIdentifier("rss-maintenance-settings")
  }

  private func settingsToggle(
    title: String,
    detail: String,
    isOn: Binding<Bool>,
    accessibilityIdentifier: String
  ) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Toggle(title, isOn: isOn)
        .accessibilityHint(detail)
        .accessibilityIdentifier(accessibilityIdentifier)

      Text(detail)
        .font(.workbenchSupporting)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityHidden(true)
    }
  }

  private func pruneHistory() {
    let summary = store.pruneReadArticles(olderThanDays: retentionDays)
    if let lastError = store.lastError, !lastError.isEmpty {
      pruneFeedback = lastError
      pruneFeedbackIsError = true
    } else {
      pruneFeedback = summary.removedArticleCount == 0
        ? String(localized: "没有符合条件的历史文章。")
        : String(
          format: String(localized: "已清理 %@ 篇文章，释放 %@ 个媒体缓存。"),
          summary.removedArticleCount.formatted(),
          summary.removedMediaAssetCount.formatted()
        )
      pruneFeedbackIsError = false
    }
  }
}
