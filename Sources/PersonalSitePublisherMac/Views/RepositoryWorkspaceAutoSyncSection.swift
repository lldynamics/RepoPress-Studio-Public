import PublishingWorkbenchCore
import SwiftUI

extension RepositoryWorkspaceView {
  @ViewBuilder
  var repositoryAutoSyncSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      ViewThatFits(in: .horizontal) {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
          repositoryAutoSyncIntroduction
          Spacer(minLength: 12)
          repositoryAutoSyncHeaderActions
        }

        VStack(alignment: .leading, spacing: 10) {
          repositoryAutoSyncIntroduction
          repositoryAutoSyncHeaderActions
        }
      }

      ViewThatFits(in: .horizontal) {
        HStack(spacing: 12) {
          repositoryAutoSyncEnabledToggle
          repositoryAutoSyncFetchToggle
          Spacer(minLength: 12)
          repositoryAutoSyncIntervalPicker
        }

        VStack(alignment: .leading, spacing: 10) {
          repositoryAutoSyncEnabledToggle
          repositoryAutoSyncFetchToggle
          repositoryAutoSyncIntervalPicker
        }
      }

      ViewThatFits(in: .horizontal) {
        HStack(spacing: 10) {
          repositoryAutoImportToggle
          repositoryAutoImportExplanation
          Spacer(minLength: 0)
        }

        VStack(alignment: .leading, spacing: 6) {
          repositoryAutoImportToggle
          repositoryAutoImportExplanation
        }
      }

      LazyVGrid(columns: repositoryMetricGridColumns, spacing: 10) {
        MetricTile(
          title: "状态",
          value: store.repositoryAutoSyncSettings.isEnabled ? store.repositoryAutoSyncState.status.localizedDisplayName : "已关闭",
          systemImage: store.repositoryAutoSyncState.status.systemImage
        )
        MetricTile(
          title: "间隔",
          value: store.repositoryAutoSyncSettings.isEnabled ? "\(store.repositoryAutoSyncSettings.normalizedIntervalMinutes) 分钟" : "-",
          systemImage: "timer"
        )
        MetricTile(
          title: "远端变更",
          value: "\(store.repositoryAutoSyncState.remoteChangedFileCount)",
          systemImage: "arrow.down.doc"
        )
        MetricTile(
          title: "待审阅文章",
          value: "\(store.repositoryAutoSyncState.importableRemoteArticleCount)",
          systemImage: "tray.and.arrow.down"
        )
      }

      LazyVGrid(
        columns: [GridItem(.adaptive(minimum: 180, maximum: 280), spacing: 10)],
        alignment: .leading,
        spacing: 8
      ) {
        if let lastRunAt = store.repositoryAutoSyncState.lastRunAt {
          Label("上次：\(lastRunAt.workbenchShortText)", systemImage: "clock.arrow.circlepath")
        }
        if let nextRunAt = store.repositoryAutoSyncState.nextRunAt, store.repositoryAutoSyncSettings.isEnabled {
          Label("下次：\(nextRunAt.workbenchShortText)", systemImage: "clock")
        }
        if let lastFetchAt = store.repositoryAutoSyncState.lastFetchAt {
          Label("Fetch：\(lastFetchAt.workbenchShortText)", systemImage: store.repositoryAutoSyncState.fetchSucceeded == false ? "exclamationmark.arrow.triangle.2.circlepath" : "arrow.triangle.2.circlepath")
        } else if store.repositoryAutoSyncState.fetchMessage != nil {
          Label("Fetch 已跳过", systemImage: "arrow.triangle.2.circlepath.circle")
        }
        if store.repositoryAutoSyncState.nonArticleRemoteChangedFileCount > 0 {
          Label("其他变更：\(store.repositoryAutoSyncState.nonArticleRemoteChangedFileCount)", systemImage: "doc.badge.gearshape")
        }
        if store.repositoryAutoSyncState.lastAutoImportedArticleCount > 0 {
          Label(
            String(
              format: String(localized: "自动导入：%d"),
              store.repositoryAutoSyncState.lastAutoImportedArticleCount
            ),
            systemImage: "tray.and.arrow.down.fill"
          )
        }
        if store.repositoryAutoSyncState.lastAutoImportConflictCount > 0 {
          Label(
            String(
              format: String(localized: "需手动合并：%d"),
              store.repositoryAutoSyncState.lastAutoImportConflictCount
            ),
            systemImage: "exclamationmark.triangle"
          )
        }
        if store.repositoryAutoSyncState.lastAutoImportDeletionCount > 0 {
          Label(
            String(
              format: String(localized: "远端删除：%d"),
              store.repositoryAutoSyncState.lastAutoImportDeletionCount
            ),
            systemImage: "trash"
          )
        }
        Button {
          guard let report = store.repositoryReport else { return }
          let files = report.remoteChangedFilesForRole(
            role: .article,
            contentRoot: store.activeProfile.contentRoot,
            assetRoot: store.activeProfile.assetRoot
          )
          presentRemoteArticleImportPreview(files)
        } label: {
          Label("导入远端文章", systemImage: "tray.and.arrow.down")
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.bordered)
        .disabled(store.repositoryAutoSyncState.importableRemoteArticleCount == 0)
        .accessibilityIdentifier("repository-auto-sync-import-articles")
      }
      .font(.callout)
      .foregroundStyle(.secondary)

      if !store.repositoryAutoSyncState.remoteChangedPaths.isEmpty {
        VStack(alignment: .leading, spacing: 8) {
          HStack {
            Label("最近远端变更", systemImage: "arrow.down.doc")
              .font(.caption.weight(.semibold))
              .foregroundStyle(.secondary)
            Spacer()
            Text("在远端 diff 审阅中导入文章或复制 diff")
              .font(.callout)
              .foregroundStyle(.secondary)
          }

          ForEach(Array(store.repositoryAutoSyncState.remoteChangedPaths.prefix(5)), id: \.self) { path in
            let identifierToken = RepositoryAccessibilityIdentifier.token(for: path)
            ViewThatFits(in: .horizontal) {
              HStack(spacing: 10) {
                repositoryAutoSyncPathIdentity(path)
                Spacer(minLength: 12)
                repositoryAutoSyncPathActions(path)
              }

              VStack(alignment: .leading, spacing: 8) {
                repositoryAutoSyncPathIdentity(path)
                repositoryAutoSyncPathActions(path)
              }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("repository-auto-sync-path-\(identifierToken)")
          }
        }
        .padding(10)
        .background(WorkbenchBackgroundStyle.panel, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("repository-auto-sync-recent-paths")
      }
    }
    .padding(14)
    .background(WorkbenchBackgroundStyle.card, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("repository-section-auto-sync")
  }

  private var repositoryAutoSyncIntroduction: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("自动检查远端")
        .font(.headline)
      Text(store.repositoryAutoSyncState.message.nilIfEmpty ?? repositoryAutoSyncDescription)
        .font(.callout)
        .foregroundStyle(.secondary)
    }
  }

  private var repositoryAutoSyncHeaderActions: some View {
    HStack(spacing: 8) {
      Button {
        copy(store.repositoryAutoSyncReviewMarkdown, message: "已复制远端自动检查审阅摘要。")
      } label: {
        Label("复制摘要", systemImage: "doc.on.doc")
      }
      .buttonStyle(.bordered)
      .accessibilityLabel("复制远端自动检查摘要")
      .accessibilityIdentifier("repository-auto-sync-copy-summary")

      Button {
        Task {
          await store.runRepositoryAutoSync()
        }
      } label: {
        Label(
          store.repositoryScanState.isScanning ? "检查中" : "立即检查",
          systemImage: "arrow.clockwise"
        )
      }
      .workbenchProminentActionStyle()
      .disabled(!store.repositoryAutoSyncSettings.isEnabled || store.repositoryScanState.isScanning)
      .accessibilityLabel("立即检查远端")
      .accessibilityIdentifier("repository-auto-sync-run")
    }
  }

  private var repositoryAutoSyncEnabledToggle: some View {
    Toggle("启用自动检查远端", isOn: repositoryAutoSyncEnabledBinding)
      .toggleStyle(.switch)
      .accessibilityLabel("启用自动检查远端")
      .accessibilityValue(store.repositoryAutoSyncSettings.isEnabled ? "开启" : "关闭")
      .accessibilityIdentifier("repository-auto-sync-enabled")
  }

  private var repositoryAutoSyncFetchToggle: some View {
    Toggle("检查前 fetch upstream", isOn: repositoryAutoSyncFetchBeforeScanBinding)
      .toggleStyle(.checkbox)
      .disabled(!store.repositoryAutoSyncSettings.isEnabled)
      .accessibilityLabel("检查前 fetch upstream")
      .accessibilityValue(store.repositoryAutoSyncSettings.fetchBeforeScan ? "开启" : "关闭")
      .accessibilityIdentifier("repository-auto-sync-fetch-upstream")
  }

  private var repositoryAutoSyncIntervalPicker: some View {
    Picker("检查间隔", selection: repositoryAutoSyncIntervalBinding) {
      ForEach(repositoryAutoSyncIntervalOptions, id: \.self) { minutes in
        Text("\(minutes) 分钟").tag(minutes)
      }
    }
    .pickerStyle(.segmented)
    .tint(WorkbenchTheme.navigationSelection)
    .frame(maxWidth: 360)
    .disabled(!store.repositoryAutoSyncSettings.isEnabled)
    .accessibilityLabel("远端自动检查间隔")
    .accessibilityValue("\(store.repositoryAutoSyncSettings.normalizedIntervalMinutes) 分钟")
    .accessibilityIdentifier("repository-auto-sync-interval")
  }

  private var repositoryAutoImportToggle: some View {
    Toggle("自动导入远端文章", isOn: repositoryAutoImportRemoteArticlesBinding)
      .toggleStyle(.checkbox)
      .disabled(!store.repositoryAutoSyncSettings.isEnabled)
      .accessibilityLabel("自动导入远端文章")
      .accessibilityValue(store.repositoryAutoSyncSettings.autoImportRemoteArticles ? "开启" : "关闭")
      .accessibilityIdentifier("repository-auto-sync-auto-import")
  }

  private var repositoryAutoImportExplanation: some View {
    Text("新文章自动导入；本地已修改、远端删除或重命名仍保留手动审阅。")
      .font(.callout)
      .foregroundStyle(.secondary)
  }

  private func repositoryAutoSyncPathIdentity(_ path: String) -> some View {
    let identifierToken = RepositoryAccessibilityIdentifier.token(for: path)
    return HStack(spacing: 8) {
      Image(systemName: "doc.text.magnifyingglass")
        .foregroundStyle(.secondary)
        .frame(width: 16)
      Text(path)
        .font(.caption.monospaced())
        .workbenchTruncatedIdentity(path)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("repository-auto-sync-path-\(identifierToken)-identity")
  }

  private func repositoryAutoSyncPathActions(_ path: String) -> some View {
    let identifierToken = RepositoryAccessibilityIdentifier.token(for: path)
    return Button {
      copy(path, message: "已复制远端自动检查发现的路径。")
    } label: {
      Label("复制路径", systemImage: "doc.on.doc")
    }
    .buttonStyle(.bordered)
    .help("复制远端路径")
    .accessibilityLabel("复制远端路径")
    .accessibilityValue(path)
    .accessibilityIdentifier("repository-auto-sync-path-\(identifierToken)-copy")
  }

  private var repositoryAutoSyncIntervalOptions: [Int] {
    [
      RepositoryAutoSyncSettings.minimumIntervalMinutes,
      15,
      30,
      60,
      RepositoryAutoSyncSettings.maximumIntervalMinutes,
    ]
  }

  private var repositoryAutoSyncDescription: String {
    store.repositoryAutoSyncSettings.autoImportRemoteArticles
      ? String(localized: "定时执行 Fetch 与差异检查；仅自动导入可确认没有本地编辑的文章。")
      : String(localized: "定时执行 Fetch 与差异检查；文章导入需要手动确认。")
  }

  private var repositoryAutoSyncEnabledBinding: Binding<Bool> {
    Binding(
      get: { store.repositoryAutoSyncSettings.isEnabled },
      set: { isEnabled in
        store.updateRepositoryAutoSyncSettings(
          RepositoryAutoSyncSettings(
            isEnabled: isEnabled,
            intervalMinutes: store.repositoryAutoSyncSettings.normalizedIntervalMinutes,
            fetchBeforeScan: store.repositoryAutoSyncSettings.fetchBeforeScan,
            autoImportRemoteArticles: store.repositoryAutoSyncSettings.autoImportRemoteArticles
          )
        )
      }
    )
  }

  private var repositoryAutoSyncFetchBeforeScanBinding: Binding<Bool> {
    Binding(
      get: { store.repositoryAutoSyncSettings.fetchBeforeScan },
      set: { fetchBeforeScan in
        store.updateRepositoryAutoSyncSettings(
          RepositoryAutoSyncSettings(
            isEnabled: store.repositoryAutoSyncSettings.isEnabled,
            intervalMinutes: store.repositoryAutoSyncSettings.normalizedIntervalMinutes,
            fetchBeforeScan: fetchBeforeScan,
            autoImportRemoteArticles: store.repositoryAutoSyncSettings.autoImportRemoteArticles
          )
        )
      }
    )
  }

  private var repositoryAutoImportRemoteArticlesBinding: Binding<Bool> {
    Binding(
      get: { store.repositoryAutoSyncSettings.autoImportRemoteArticles },
      set: { autoImportRemoteArticles in
        store.updateRepositoryAutoSyncSettings(
          RepositoryAutoSyncSettings(
            isEnabled: store.repositoryAutoSyncSettings.isEnabled,
            intervalMinutes: store.repositoryAutoSyncSettings.normalizedIntervalMinutes,
            fetchBeforeScan: store.repositoryAutoSyncSettings.fetchBeforeScan,
            autoImportRemoteArticles: autoImportRemoteArticles
          )
        )
      }
    )
  }

  private var repositoryAutoSyncIntervalBinding: Binding<Int> {
    Binding(
      get: { store.repositoryAutoSyncSettings.normalizedIntervalMinutes },
      set: { intervalMinutes in
        store.updateRepositoryAutoSyncSettings(
          RepositoryAutoSyncSettings(
            isEnabled: store.repositoryAutoSyncSettings.isEnabled,
            intervalMinutes: intervalMinutes,
            fetchBeforeScan: store.repositoryAutoSyncSettings.fetchBeforeScan,
            autoImportRemoteArticles: store.repositoryAutoSyncSettings.autoImportRemoteArticles
          )
        )
      }
    )
  }
}
