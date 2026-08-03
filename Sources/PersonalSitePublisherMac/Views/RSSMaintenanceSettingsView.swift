import PublishingWorkbenchCore
import SwiftUI

@MainActor
struct RSSMaintenanceSettingsView: View {
  @ObservedObject var store: RSSReaderStore

  @AppStorage(RSSReaderStore.automaticPruningDefaultsKey)
  private var automaticPruningEnabled = false
  @AppStorage(RSSReaderStore.retentionDaysDefaultsKey)
  private var retentionDays = RSSReaderStore.defaultRetentionDays

  var body: some View {
    Form {
      Section(String(localized: "本地 RSS 缓存")) {
        LabeledContent("订阅数量", value: store.feeds.count.formatted())
        LabeledContent("本机文章", value: store.articleHeaders.count.formatted())
        LabeledContent("已归档图片", value: store.mediaAssets.count.formatted())
        Text("将文章加入稍后阅读或添加高亮后，文章中的图片会在后台保存到本机。遇到防盗链时会先带文章 Referer 重试，再降级为无 Referer 请求。")
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      Section(String(localized: "自动清理历史文章")) {
        Toggle("启用自动清理", isOn: $automaticPruningEnabled)
          .onChange(of: automaticPruningEnabled) { _, enabled in
            store.updateRetentionSettings(enabled: enabled, days: retentionDays)
          }

        Picker("保留最近", selection: $retentionDays) {
          ForEach([30, 60, 90, 180, 365, 730], id: \.self) { days in
            Text("最近 \(days) 天").tag(days)
          }
        }
        .onChange(of: retentionDays) { _, days in
          store.updateRetentionSettings(enabled: automaticPruningEnabled, days: days)
        }
        .disabled(!automaticPruningEnabled)

        Text("只会清理超过保留期限、已读、未加入稍后阅读且没有高亮的文章；稍后阅读文章、批注和已归档图片不会被误删。")
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)

        HStack {
          Button("立即清理", systemImage: "trash") {
            _ = store.pruneReadArticles(olderThanDays: retentionDays)
          }
          .buttonStyle(.bordered)

          if let summary = store.lastPruneSummary {
            Text(
              summary.removedArticleCount == 0
                ? "没有符合条件的历史文章。"
                : "已清理 \(summary.removedArticleCount) 篇文章，释放 \(summary.removedMediaAssetCount) 个图片缓存。"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
          }
        }
      }
    }
    .formStyle(.grouped)
    .padding()
    .accessibilityIdentifier("rss-maintenance-settings")
  }
}
