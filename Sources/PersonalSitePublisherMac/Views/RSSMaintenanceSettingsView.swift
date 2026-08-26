import PublishingWorkbenchCore
import SwiftUI

@MainActor
struct RSSMaintenanceSettingsView: View {
  @ObservedObject var store: RSSReaderStore
  let allowsBackgroundRefresh: Bool

  @AppStorage(RSSReaderStore.automaticPruningDefaultsKey)
  private var automaticPruningEnabled = false
  @AppStorage(RSSReaderStore.retentionDaysDefaultsKey)
  private var retentionDays = RSSReaderStore.defaultRetentionDays
  @AppStorage(RSSReaderUserPreferences.backgroundRefreshEnabledKey)
  private var backgroundRefreshEnabled = RSSReaderUserPreferences.defaultBackgroundRefreshEnabled
  @AppStorage(RSSReaderUserPreferences.backgroundRefreshIntervalMinutesKey)
  private var backgroundRefreshIntervalMinutes =
    RSSReaderUserPreferences.defaultBackgroundRefreshIntervalMinutes
  @AppStorage(RSSReaderUserPreferences.automaticMarkReadAtEndEnabledKey)
  private var automaticMarkReadAtEndEnabled =
    RSSReaderUserPreferences.defaultAutomaticMarkReadAtEndEnabled
  @AppStorage(RSSReaderUserPreferences.remoteImagesEnabledKey)
  private var defaultRemoteImagesEnabled = RSSReaderUserPreferences.defaultRemoteImagesEnabled
  @AppStorage(RSSReaderUserPreferences.automaticTranslationEnabledKey)
  private var automaticTranslationEnabled = RSSReaderUserPreferences.defaultAutomaticTranslationEnabled
  @AppStorage(RSSReaderUserPreferences.translationBackendKey)
  private var translationBackendRawValue =
    RSSReaderUserPreferences.defaultTranslationBackend.rawValue
  @AppStorage(RSSReaderUserPreferences.offlineCacheFullTextOnRefreshEnabledKey)
  private var offlineCacheFullTextOnRefreshEnabled =
    RSSReaderUserPreferences.defaultOfflineCacheFullTextOnRefreshEnabled
  @AppStorage(RSSReaderUserPreferences.automaticFullTextExtractionEnabledKey)
  private var automaticFullTextExtractionEnabled =
    RSSReaderUserPreferences.defaultAutomaticFullTextExtractionEnabled
  @State private var isPruneConfirmationPresented = false
  @State private var pruneFeedback: String?
  @State private var pruneFeedbackIsError = false
  @State private var opmlFeedback: String?
  @State private var opmlFeedbackIsError = false
  @State private var isOfflineCachingAll = false
  @State private var offlineCacheFeedback: String?

  var body: some View {
    Form {
      Section(String(localized: "本地 RSS 缓存")) {
        LabeledContent("订阅数量", value: store.feeds.count.formatted())
        LabeledContent("本机文章", value: store.articleHeaders.count.formatted())
        Text("RSS 默认保存 Feed 返回的摘要和正文。启用全文提取或离线缓存全文后，还会访问原网站并保存净化后的正文；关闭这些选项后不会新增原网页全文。历史网页快照和媒体缓存仍可读取。")
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)

        VStack(alignment: .leading, spacing: 8) {
          Button {
            startOfflineCachingAllArticles()
          } label: {
            Label(
              isOfflineCachingAll
                ? String(localized: "正在离线缓存全文…")
                : String(localized: "立即离线缓存所有文章全文"),
              systemImage: isOfflineCachingAll ? "arrow.triangle.2.circlepath" : "arrow.down.doc.fill"
            )
          }
          .buttonStyle(.bordered)
          .disabled(isOfflineCachingAll || store.articleHeaders.isEmpty)

          if let offlineCacheFeedback {
            Text(offlineCacheFeedback)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      }

      Section(String(localized: "自动刷新与阅读")) {
        Toggle(
          String(localized: "后台自动刷新 RSS"),
          isOn: backgroundRefreshEnabledBinding
        )
        .toggleStyle(.switch)
        .accessibilityLabel(String(localized: "后台自动刷新 RSS"))
        .accessibilityValue(
          !allowsBackgroundRefresh
            ? String(localized: "安全模式下暂停")
            : backgroundRefreshEnabled
            ? String(localized: "开启")
            : String(localized: "关闭")
        )
        .accessibilityHint(
          String(localized: "关闭后会停止自动刷新计时器和失败订阅重试计时器；手动刷新仍可使用。")
        )
        .accessibilityIdentifier("rss-background-refresh-enabled")
        .disabled(!allowsBackgroundRefresh)

        if !allowsBackgroundRefresh {
          Text("安全模式下后台刷新保持暂停；退出安全模式后会按此设置恢复。")
            .font(.workbenchSupporting)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }

        Picker(
          String(localized: "自动刷新间隔"),
          selection: backgroundRefreshIntervalBinding
        ) {
          ForEach(RSSReaderUserPreferences.backgroundRefreshIntervalOptions, id: \.self) { minutes in
            Text("\(minutes) 分钟").tag(minutes)
          }
        }
        .pickerStyle(.menu)
        .disabled(!allowsBackgroundRefresh || !backgroundRefreshEnabled)
        .accessibilityLabel(String(localized: "RSS 自动刷新间隔"))
        .accessibilityValue(
          "\(RSSReaderUserPreferences.normalizedBackgroundRefreshIntervalMinutes(backgroundRefreshIntervalMinutes)) 分钟"
        )
        .accessibilityHint(String(localized: "修改后会立即替换正在运行的自动刷新计时器。"))
        .accessibilityIdentifier("rss-background-refresh-interval")

        Text("自动刷新只检查已到刷新时间的订阅；关闭后台自动刷新不会影响手动刷新。")
          .font(.workbenchSupporting)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)

        Toggle(
          String(localized: "读到文章末尾时自动标记为已读"),
          isOn: $automaticMarkReadAtEndEnabled
        )
        .toggleStyle(.checkbox)
        .accessibilityLabel(String(localized: "读到文章末尾时自动标记为已读"))
        .accessibilityValue(
          automaticMarkReadAtEndEnabled
            ? String(localized: "开启")
            : String(localized: "关闭")
        )
        .accessibilityHint(
          String(localized: "关闭后仍会保存阅读进度，但读到正文末尾不会改变已读状态。")
        )
        .accessibilityIdentifier("rss-automatic-mark-read-at-end")

        settingsToggle(
          title: String(localized: "刷新时自动离线缓存全文"),
          detail: String(localized: "刷新订阅源时，自动在后台从原网站抓取截断文章的完整正文并持久化存储，无需网络即可离线阅读。"),
          isOn: Binding(
            get: { offlineCacheFullTextOnRefreshEnabled },
            set: { newValue in
              offlineCacheFullTextOnRefreshEnabled = newValue
              store.isOfflineCacheFullTextEnabled = newValue
            }
          ),
          accessibilityIdentifier: "rss-offline-cache-on-refresh"
        )
      }
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("rss-automation-settings")

      Section(String(localized: "阅读默认值")) {
        settingsToggle(
          title: String(localized: "默认加载远程图片"),
          detail: String(localized: "打开或切换文章时使用此默认值；会连接文章中的第三方图片地址。文章内的“加载远程图片”开关仍可临时覆盖。"),
          isOn: $defaultRemoteImagesEnabled,
          accessibilityIdentifier: "rss-default-remote-images"
        )

        Picker(
          String(localized: "翻译引擎"),
          selection: translationBackendBinding
        ) {
          Text(String(localized: "Apple 本机翻译"))
            .tag(RSSArticleTranslationBackend.apple)
            .disabled(!isAppleTranslationAvailable)
          Text(String(localized: "当前 AI 服务"))
            .tag(RSSArticleTranslationBackend.ai)
        }
        .accessibilityLabel(String(localized: "RSS 翻译引擎"))
        .accessibilityValue(translationBackendName)
        .accessibilityHint(translationBackendHint)
        .accessibilityIdentifier("rss-translation-backend")

        Text(translationBackendDescription)
          .font(.workbenchSupporting)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)

        settingsToggle(
          title: String(localized: "打开文章时自动翻译"),
          detail: automaticTranslationDescription,
          isOn: $automaticTranslationEnabled,
          accessibilityIdentifier: "rss-automatic-translation"
        )

        settingsToggle(
          title: String(localized: "打开截断文章时自动提取全文"),
          detail: String(localized: "遇到仅含摘要的订阅源时，自动从原网站安全下载并净化展开完整正文；文章内仍可手动恢复原始摘要。"),
          isOn: $automaticFullTextExtractionEnabled,
          accessibilityIdentifier: "rss-automatic-full-text-extraction"
        )
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
          AccessibleStatusMessage(
            message: opmlFeedback,
            severity: opmlFeedbackIsError ? .error : .success,
            announcesNonUrgentStatus: true
          )
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

        Text("只有启用全文提取或离线缓存全文时，才会从原网站新增净化后的正文；媒体归档已停止新增，历史数据仅作兼容读取。")
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

        ViewThatFits(in: .horizontal) {
          HStack(spacing: WorkbenchSpacing.control) {
            pruneButton
            pruneStatus
          }

          VStack(alignment: .leading, spacing: WorkbenchSpacing.control) {
            pruneButton
            pruneStatus
          }
        }
      }
    }
    .formStyle(.grouped)
    .scrollIndicators(.automatic)
    .padding(WorkbenchSpacing.content)
    .onAppear {
      normalizeBackgroundRefreshInterval()
      normalizeTranslationBackend()
      synchronizeBackgroundRefresh()
      store.isOfflineCacheFullTextEnabled = offlineCacheFullTextOnRefreshEnabled
    }
    .onChange(of: backgroundRefreshEnabled) { _, _ in
      synchronizeBackgroundRefresh()
    }
    .onChange(of: backgroundRefreshIntervalMinutes) { _, _ in
      synchronizeBackgroundRefresh()
    }
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
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("rss-maintenance-settings")
  }

  private var pruneButton: some View {
    Button("立即清理", systemImage: "trash", role: .destructive) {
      isPruneConfirmationPresented = true
    }
    .buttonStyle(.bordered)
  }

  @ViewBuilder
  private var pruneStatus: some View {
    if let pruneFeedback {
      AccessibleStatusMessage(
        message: pruneFeedback,
        severity: pruneFeedbackIsError ? .error : .success,
        announcesNonUrgentStatus: true
      )
      .fixedSize(horizontal: false, vertical: true)
    }
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

  private var backgroundRefreshEnabledBinding: Binding<Bool> {
    Binding(
      get: { backgroundRefreshEnabled },
      set: { isEnabled in
        backgroundRefreshEnabled = isEnabled
        synchronizeBackgroundRefresh()
      }
    )
  }

  private var backgroundRefreshIntervalBinding: Binding<Int> {
    Binding(
      get: {
        RSSReaderUserPreferences.normalizedBackgroundRefreshIntervalMinutes(
          backgroundRefreshIntervalMinutes
        )
      },
      set: { minutes in
        backgroundRefreshIntervalMinutes =
          RSSReaderUserPreferences.normalizedBackgroundRefreshIntervalMinutes(minutes)
        synchronizeBackgroundRefresh()
      }
    )
  }

  private func normalizeBackgroundRefreshInterval() {
    let normalized = RSSReaderUserPreferences.normalizedBackgroundRefreshIntervalMinutes(
      backgroundRefreshIntervalMinutes
    )
    guard normalized != backgroundRefreshIntervalMinutes else { return }
    backgroundRefreshIntervalMinutes = normalized
  }

  private var isAppleTranslationAvailable: Bool {
    RSSReaderUserPreferences.isAppleTranslationAvailable
  }

  private var selectedTranslationBackend: RSSArticleTranslationBackend {
    RSSReaderUserPreferences.translationBackend(defaults: .standard)
  }

  private var translationBackendBinding: Binding<RSSArticleTranslationBackend> {
    Binding(
      get: { selectedTranslationBackend },
      set: { backend in
        guard backend != .apple || isAppleTranslationAvailable else { return }
        translationBackendRawValue = backend.rawValue
      }
    )
  }

  private var translationBackendName: String {
    switch selectedTranslationBackend {
    case .apple:
      return String(localized: "Apple 本机翻译")
    case .ai:
      return String(localized: "当前 AI 服务")
    }
  }

  private var translationBackendDescription: String {
    switch selectedTranslationBackend {
    case .apple where isAppleTranslationAvailable:
      return String(localized: "标题和正文在设备端处理，不会发送给 AI；首次使用某种语言时，Apple 可能要求下载语言包。")
    case .apple:
      return String(localized: "Apple 本机翻译在 macOS 14 不可用，请选择当前 AI 服务。")
    case .ai:
      return String(localized: "当前 AI 服务会发送文章标题和正文，并受 AI 远程总闸与目的地授权约束。")
    }
  }

  private var automaticTranslationDescription: String {
    switch selectedTranslationBackend {
    case .apple:
      return String(localized: "Apple 本机翻译只会在目标语言包已安装时自动翻译；未安装时不会自动下载或弹出提示，标题和正文在本机设备端处理。")
    case .ai:
      return String(localized: "会把当前文章标题和正文发送给当前 AI 服务，并受 AI 远程总闸与目的地授权约束；文章内仍可手动关闭或重新翻译。")
    }
  }

  private var translationBackendHint: String {
    switch selectedTranslationBackend {
    case .apple:
      return String(localized: "标题和正文仅在本机处理，不需要 AI 发送授权。")
    case .ai:
      return String(localized: "标题和正文会按当前 AI 发送权限发送给 AI 服务。")
    }
  }

  private func normalizeTranslationBackend() {
    let normalized = RSSReaderUserPreferences.translationBackend(defaults: .standard)
    guard translationBackendRawValue != normalized.rawValue else { return }
    translationBackendRawValue = normalized.rawValue
  }

  private func synchronizeBackgroundRefresh() {
    normalizeBackgroundRefreshInterval()
    store.configureBackgroundRefresh(
      enabled: allowsBackgroundRefresh && backgroundRefreshEnabled,
      interval: RSSReaderUserPreferences.backgroundRefreshIntervalSeconds(
        backgroundRefreshIntervalMinutes
      )
    )
  }

  private func pruneHistory() {
    let summary = store.pruneReadArticles(olderThanDays: retentionDays)
    if let lastError = store.lastError, !lastError.isEmpty {
      pruneFeedback = lastError
      pruneFeedbackIsError = true
    } else {
      pruneFeedback =
        summary.removedArticleCount == 0
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
      let excludedSuffix =
        result.excludedSubscriptionCount > 0
        ? "，已排除 " + result.excludedSubscriptionCount.formatted() + " 个风险订阅"
        : ""
      opmlFeedback =
        "已导出 " + result.exportedSubscriptionCount.formatted()
        + " 个订阅到 " + result.destinationURL.lastPathComponent + excludedSuffix + "。"
    } catch {
      opmlFeedback = "OPML 导出失败：" + error.localizedDescription
      opmlFeedbackIsError = true
    }
  }

  private func startOfflineCachingAllArticles() {
    guard !isOfflineCachingAll else { return }
    isOfflineCachingAll = true
    offlineCacheFeedback = String(localized: "正在后台分析并离线缓存文章全文…")
    let articleIDs = store.articleHeaders.map(\.id)
    Task {
      let count = await store.prefetchFullTextForOfflineCache(articleIDs: articleIDs)
      await MainActor.run {
        isOfflineCachingAll = false
        offlineCacheFeedback = String(
          format: String(localized: "已完成离线缓存，共提取并持久化 %@ 篇截断文章全文。"),
          count.formatted()
        )
      }
    }
  }
}
