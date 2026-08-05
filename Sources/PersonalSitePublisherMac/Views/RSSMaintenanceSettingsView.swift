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
  @State private var opmlFeedback: String?
  @State private var opmlFeedbackIsError = false

  var body: some View {
    Form {
      Section(String(localized: "本地 RSS 缓存")) {
        LabeledContent("订阅数量", value: store.feeds.count.formatted())
        LabeledContent("本机文章", value: store.articleHeaders.count.formatted())
        Text("RSS 只保存 Feed 实际返回的摘要和正文。旧版本已经保存的网页快照和媒体缓存仍可读取，但不会再自动抓取或归档新内容。")
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      Section(String(localized: "订阅迁移")) {
        Text("低频的 OPML 导入和导出放在这里；文件只包含订阅名称与地址，不包含文章缓存或阅读状态。")
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)

        HStack {
          Button("导入 OPML", systemImage: "square.and.arrow.down") {
            importOPML()
          }

          Button("导出 OPML", systemImage: "square.and.arrow.up") {
            exportOPML()
          }
          .disabled(store.feeds.isEmpty)
        }

        if let opmlFeedback {
          Label(
            opmlFeedback,
            systemImage: opmlFeedbackIsError ? "exclamationmark.triangle" : "checkmark.circle"
          )
          .font(.caption)
          .foregroundStyle(opmlFeedbackIsError ? WorkbenchTheme.warning : Color.secondary)
          .textSelection(.enabled)
        }
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

        Text("网页全文快照和媒体归档已停止新增；历史数据仅作兼容读取。")
          .font(.workbenchSupporting)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
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

        Text("只会清理超过保留期限、已读、未加入稍后阅读且没有高亮的文章；稍后阅读文章和批注不会被误删。")
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
    .scrollIndicators(.automatic)
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
        : String(format: String(localized: "已清理 %@ 篇文章。"), summary.removedArticleCount.formatted())
      pruneFeedbackIsError = false
    }
  }

  private func importOPML() {
    opmlFeedback = nil
    opmlFeedbackIsError = false
    do {
      guard let result = try RSSOPMLFileTransferService.importOPML(into: store) else { return }
      opmlFeedback = "已导入 " + result.feedIDs.count.formatted() + " 个订阅，正在读取最新文章。"
      Task { @MainActor in
        for feedID in result.feedIDs {
          await store.refresh(feedID: feedID)
        }
      }
    } catch {
      opmlFeedback = error.localizedDescription
      opmlFeedbackIsError = true
    }
  }

  private func exportOPML() {
    opmlFeedback = nil
    opmlFeedbackIsError = false
    do {
      guard let result = try RSSOPMLFileTransferService.exportOPML(from: store) else { return }
      let excludedSuffix = result.excludedSubscriptionCount > 0
        ? "，已排除 " + result.excludedSubscriptionCount.formatted() + " 个风险订阅"
        : ""
      opmlFeedback = "已导出 " + result.exportedSubscriptionCount.formatted()
        + " 个订阅到 " + result.destinationURL.lastPathComponent + excludedSuffix + "。"
    } catch {
      opmlFeedback = "OPML 导出失败：" + error.localizedDescription
      opmlFeedbackIsError = true
    }
  }
}
