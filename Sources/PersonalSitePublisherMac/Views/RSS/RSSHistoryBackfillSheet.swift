import PublishingKnowledgeCore
import SwiftUI

struct RSSHistoryBackfillSheet: View {
  @ObservedObject var store: RSSReaderStore
  let feed: RSSFeed
  @Environment(\.dismiss) private var dismiss
  @State private var directoryAddress = ""
  @State private var errorMessage: String?

  private var progress: RSSHistoryBackfillProgress? {
    store.historyBackfillProgress.flatMap { $0.feedID == feed.id ? $0 : nil }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: WorkbenchSpacing.card) {
      Text("补齐历史文章")
        .font(.title2.weight(.semibold))
      Text(feed.displayTitle)
        .font(.headline)
      Text("从作者公开目录寻找历史链接，每批处理 20 篇。可发现的链接与正文获取结果分别统计；部分网站无法补齐全部历史。")
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      TextField("公开文章目录地址", text: $directoryAddress)
        .textFieldStyle(.roundedBorder)
        .accessibilityLabel("公开文章目录地址")
        .accessibilityIdentifier("rss-history-directory-address")
        .disabled(store.isHistoryBackfillRunning)
      Text("仅读取该订阅网站内明确标记的文章目录、下一页与网站公布的 sitemap，不跟随其他网站。已有文章、阅读状态与写作草稿会保留。")
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      if store.isHistoryBackfillRunning, progress == nil {
        Text("其他订阅正在补齐，请等待或打开该订阅查看进度。")
          .foregroundStyle(.secondary)
      }
      if let progress {
        if store.isHistoryBackfillRunning {
          ProgressView()
            .controlSize(.small)
            .accessibilityLabel("正在补齐历史文章")
        }
        Grid(alignment: .leading, horizontalSpacing: WorkbenchSpacing.card) {
          countRow(String(localized: "发现链接"), count: progress.discoveredCount)
          countRow(String(localized: "新增文章"), count: progress.addedCount)
          countRow(String(localized: "重复文章"), count: progress.duplicateCount)
          countRow(String(localized: "正文可用"), count: progress.fullTextSuccessCount)
          countRow(String(localized: "正文失败"), count: progress.fullTextFailureCount)
        }
        .accessibilityIdentifier("rss-history-progress")
        Text(progress.message)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        if let retryAt = progress.retryAt, retryAt > Date() {
          Text("可以继续的时间：\(retryAt.formatted(date: .abbreviated, time: .shortened))")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
      }
      if let errorMessage { Text(errorMessage).foregroundStyle(WorkbenchTheme.risk) }
      HStack {
        Button("关闭") { dismiss() }
          .keyboardShortcut(.cancelAction)
        Spacer()
        if store.isHistoryBackfillRunning {
          Button("取消补齐") { store.cancelHistoryBackfill() }
            .disabled(progress == nil)
            .accessibilityIdentifier("rss-history-cancel")
        } else {
          if progress?.canRetryFailures == true {
            Button("重试失败正文") { start(retryFailures: true) }
          }
          Button(actionTitle) { start() }
            .workbenchProminentActionStyle()
            .disabled(
              directoryAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("rss-history-start")
        }
      }
    }
    .padding(WorkbenchSpacing.page)
    .frame(width: 520)
    .onAppear {
      #if DEBUG || SCREENSHOT_CAPTURE_BUILD
        RSSHistoryBackfillUIFixture.prepareLargeFixtureIfNeeded(store: store, feed: feed)
      #endif
      directoryAddress = feed.siteURL?.absoluteString ?? ""
      do {
        try store.loadHistoryBackfillProgress(feedID: feed.id)
        if let progress { directoryAddress = progress.directoryURL.absoluteString }
      } catch { errorMessage = error.localizedDescription }
    }
  }

  private var actionTitle: String {
    if progress?.canResume == true { return String(localized: "继续补齐") }
    if progress?.status == .completed { return String(localized: "重新发现历史链接") }
    return String(localized: "开始补齐")
  }

  private func countRow(_ title: String, count: Int) -> some View {
    GridRow {
      Text(title)
      Text(count.formatted()).monospacedDigit()
    }
  }

  private func start(retryFailures: Bool = false) {
    guard let url = URL(string: directoryAddress.trimmingCharacters(in: .whitespacesAndNewlines)),
      ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil
    else {
      errorMessage = String(localized: "请填写有效的公开目录网页地址。")
      return
    }
    errorMessage = nil
    #if DEBUG || SCREENSHOT_CAPTURE_BUILD
      if let service = RSSHistoryBackfillUIFixture.service(for: url) {
        store.startHistoryBackfill(
          feedID: feed.id, directoryURL: url, service: service, retryFailures: retryFailures)
        return
      }
    #endif
    store.startHistoryBackfill(feedID: feed.id, directoryURL: url, retryFailures: retryFailures)
  }
}
