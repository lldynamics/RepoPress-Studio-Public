import Foundation

public struct RepositoryAutoSyncReviewService {
  public init() {}

  public func markdown(
    settings: RepositoryAutoSyncSettings,
    state: RepositoryAutoSyncState,
    report: RepositoryScanReport?,
    profile: SiteProfile,
    maxFilesPerSection: Int = 8
  ) -> String {
    var lines: [String] = [
      "# 远端自动检查审阅",
      "",
      "- 状态：\(settings.isEnabled ? state.status.displayName : RepositoryAutoSyncStatus.disabled.displayName)",
      "- 扫描间隔：\(settings.isEnabled ? "\(settings.normalizedIntervalMinutes) 分钟" : "已关闭")",
      "- 扫描前 fetch upstream：\(settings.fetchBeforeScan ? "是" : "否")",
      "- 自动导入远端文章：\(settings.autoImportRemoteArticles ? "是" : "否")",
    ]

    if let lastRunAt = state.lastRunAt {
      lines.append("- 上次扫描：\(formattedDate(lastRunAt))")
    }
    if settings.isEnabled, let nextRunAt = state.nextRunAt {
      lines.append("- 下次扫描：\(formattedDate(nextRunAt))")
    }
    if let fetchMessage = state.fetchMessage?.trimmedForPublishing, !fetchMessage.isEmpty {
      let fetchState = state.fetchSucceeded.map { $0 ? "成功" : "失败" } ?? "跳过"
      lines.append("- Fetch：\(fetchState)，\(fetchMessage)")
    }
    if let lastAutoImportAt = state.lastAutoImportAt {
      lines.append("- 上次自动导入检查：\(formattedDate(lastAutoImportAt))")
      lines.append("- 自动导入文章：\(state.lastAutoImportedArticleCount)")
      lines.append("- 本地冲突：\(state.lastAutoImportConflictCount)")
      lines.append("- 远端删除待确认：\(state.lastAutoImportDeletionCount)")
    }
    if let lastRemotePublishAt = state.lastRemotePublishAt {
      lines.append("- 最近线上发布：\(formattedDate(lastRemotePublishAt))")
      if let provider = state.lastRemotePublishProvider {
        lines.append("- 发布平台：\(provider.displayName)")
      }
      if let mode = state.lastRemotePublishMode {
        lines.append("- 发布方式：\(mode.displayName)")
      }
    }

    if let report {
      lines.append("- 仓库：\(report.rootPath.isEmpty ? "未选择" : report.rootPath)")
      if let branchStatus = report.branchStatus {
        lines.append("- 分支：\(branchStatus.displayName)")
        lines.append("- Upstream：\(branchStatus.upstreamName ?? "未设置")")
        lines.append("- 同步状态：\(branchStatus.syncStatusTitle)")
      } else {
        lines.append("- 分支：未识别")
      }
    } else {
      lines.append("- 仓库：未扫描")
    }

    lines.append(contentsOf: [
      "",
      "## 远端变更",
      "",
      "- 远端文件：\(state.remoteChangedFileCount)",
      "- 可导入文章：\(state.importableRemoteArticleCount)",
      "- 其他变更：\(state.nonArticleRemoteChangedFileCount)",
    ])

    let rawQueueSections = report?.remoteChangeQueueSections(
      contentRoot: profile.contentRoot,
      assetRoot: profile.assetRoot
    ) ?? []
    let queueSections = filteredQueueSections(rawQueueSections, state: state)

    lines.append(contentsOf: [
      "",
      "## 建议动作",
      "",
    ])
    lines.append(contentsOf: recommendedActions(settings: settings, state: state, report: report, queueSections: queueSections))

    if !queueSections.isEmpty {
      lines.append(contentsOf: [
        "",
        "## 变更队列",
        "",
      ])
      for section in queueSections {
        lines.append("### \(section.title)（\(section.count)）")
        for file in section.files.prefix(max(1, maxFilesPerSection)) {
          lines.append("- \(file.kind.displayName)：\(file.displayPath)")
        }
        let hiddenCount = section.files.count - max(1, maxFilesPerSection)
        if hiddenCount > 0 {
          lines.append("- 还有 \(hiddenCount) 个未列出")
        }
        lines.append("")
      }
      while lines.last == "" {
        lines.removeLast()
      }
    } else if !state.remoteChangedPaths.isEmpty {
      lines.append(contentsOf: [
        "",
        "## 变更队列",
        "",
      ])
      for path in state.remoteChangedPaths.prefix(max(1, maxFilesPerSection)) {
        lines.append("- \(path)")
      }
      let hiddenCount = state.remoteChangedPaths.count - max(1, maxFilesPerSection)
      if hiddenCount > 0 {
        lines.append("- 还有 \(hiddenCount) 个未列出")
      }
    }

    if !state.lastRemotePublishPaths.isEmpty {
      lines.append(contentsOf: [
        "",
        "## 最近线上写入",
        "",
      ])
      for path in state.lastRemotePublishPaths.prefix(max(1, maxFilesPerSection)) {
        lines.append("- \(path)")
      }
      let hiddenCount = state.lastRemotePublishPaths.count - max(1, maxFilesPerSection)
      if hiddenCount > 0 {
        lines.append("- 还有 \(hiddenCount) 个未列出")
      }
    }

    return lines.joined(separator: "\n")
  }

  private func filteredQueueSections(
    _ sections: [RepositoryChangeQueueSection],
    state: RepositoryAutoSyncState
  ) -> [RepositoryChangeQueueSection] {
    let pendingPaths = Set(state.remoteChangedPaths.map { $0.normalizedRelativePath() })
    if pendingPaths.isEmpty {
      return state.remoteChangedFileCount == 0 ? [] : sections
    }
    return sections.compactMap { section in
      let files = section.files.filter { pendingPaths.contains($0.displayPath.normalizedRelativePath()) }
      guard !files.isEmpty else {
        return nil
      }
      return RepositoryChangeQueueSection(role: section.role, files: files)
    }
  }

  private func recommendedActions(
    settings: RepositoryAutoSyncSettings,
    state: RepositoryAutoSyncState,
    report: RepositoryScanReport?,
    queueSections: [RepositoryChangeQueueSection]
  ) -> [String] {
    if !settings.isEnabled {
      return ["- 启用自动检查远端后再生成远端变更队列；自动导入默认关闭。"]
    }
    guard let report else {
      return ["- 先扫描本地仓库，确认 upstream 和远端变更。"]
    }
    guard report.hasGitDirectory else {
      return ["- 当前目录不是 Git 工作树，先选择真实站点仓库。"]
    }
    guard report.branchStatus?.upstreamName != nil else {
      return ["- 先设置 upstream，再让远端自动检查执行 Fetch 与差异检查。"]
    }
    if state.fetchSucceeded == false {
      return ["- Fetch 失败，先修复远端权限或网络，再重新扫描。"]
    }
    if state.remoteChangedFileCount == 0 {
      return ["- 当前没有远端待拉取变化，可以继续发布前检查。"]
    }

    var actions: [String] = []
    if state.importableRemoteArticleCount > 0 {
      if settings.autoImportRemoteArticles {
        actions.append("- 手动审阅 \(state.importableRemoteArticleCount) 篇未自动导入的文章；本地内容不会被覆盖。")
      } else {
        actions.append("- 先导入 \(state.importableRemoteArticleCount) 篇远端文章草稿，再处理本地发布。")
      }
    }
    if state.lastAutoImportDeletionCount > 0 {
      actions.append("- 审阅 \(state.lastAutoImportDeletionCount) 篇远端删除；自动检查不会删除本地草稿。")
    }
    if queueSections.contains(where: { $0.role == .configuration || $0.role == .image }) {
      actions.append("- 审阅图片或配置变更，确认不会影响站点构建和社交预览。")
    }
    if queueSections.contains(where: { $0.role == .other }) {
      actions.append("- 其他远端变更不直接导入文章，但发布前仍应确认 diff。")
    }
    if actions.isEmpty {
      actions.append("- 审阅远端 diff 后再继续发布。")
    }
    return actions
  }

  private func formattedDate(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter.string(from: date)
  }
}
