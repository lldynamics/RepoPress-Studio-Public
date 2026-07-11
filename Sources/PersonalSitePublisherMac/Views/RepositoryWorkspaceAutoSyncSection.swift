import PublishingWorkbenchCore
import SwiftUI

extension RepositoryWorkspaceView {
  @ViewBuilder
  var repositoryAutoSyncSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: 3) {
          Text("自动同步")
            .font(.headline)
          Text(store.repositoryAutoSyncState.message)
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button {
          copy(store.repositoryAutoSyncReviewMarkdown, message: "已复制自动同步审阅摘要。")
        } label: {
          Label("复制摘要", systemImage: "doc.on.doc")
        }
        .accessibilityLabel("复制自动同步摘要")
        Button {
          Task {
            await store.runRepositoryAutoSync()
          }
        } label: {
          Label(
            store.repositoryScanState.isScanning ? "扫描中" : "立即扫描",
            systemImage: "arrow.clockwise"
          )
        }
        .disabled(!store.repositoryAutoSyncSettings.isEnabled || store.repositoryScanState.isScanning)
        .accessibilityLabel("立即扫描自动同步")
      }

      HStack(spacing: 12) {
        Toggle("启用自动同步", isOn: repositoryAutoSyncEnabledBinding)
          .toggleStyle(.switch)
          .accessibilityLabel("启用自动同步")
          .accessibilityValue(store.repositoryAutoSyncSettings.isEnabled ? "开启" : "关闭")
        Toggle("扫描前 fetch upstream", isOn: repositoryAutoSyncFetchBeforeScanBinding)
          .toggleStyle(.checkbox)
          .disabled(!store.repositoryAutoSyncSettings.isEnabled)
          .accessibilityLabel("扫描前 fetch upstream")
          .accessibilityValue(store.repositoryAutoSyncSettings.fetchBeforeScan ? "开启" : "关闭")

        Spacer()

        Picker("扫描间隔", selection: repositoryAutoSyncIntervalBinding) {
          ForEach(repositoryAutoSyncIntervalOptions, id: \.self) { minutes in
            Text("\(minutes) 分钟").tag(minutes)
          }
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 360)
        .disabled(!store.repositoryAutoSyncSettings.isEnabled)
        .accessibilityLabel("自动同步扫描间隔")
        .accessibilityValue("\(store.repositoryAutoSyncSettings.normalizedIntervalMinutes) 分钟")
      }

      LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
        MetricTile(
          title: "状态",
          value: store.repositoryAutoSyncSettings.isEnabled ? store.repositoryAutoSyncState.status.displayName : "已关闭",
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
          title: "可导入文章",
          value: "\(store.repositoryAutoSyncState.importableRemoteArticleCount)",
          systemImage: "tray.and.arrow.down"
        )
      }

      HStack(spacing: 12) {
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
        Spacer()
        Button {
          store.importRemoteChangedArticleDraftsFromRepository()
        } label: {
          Label("导入远端文章", systemImage: "tray.and.arrow.down")
        }
        .disabled(store.repositoryAutoSyncState.importableRemoteArticleCount == 0)
      }
      .font(.caption)
      .foregroundStyle(.secondary)

      if !store.repositoryAutoSyncState.remoteChangedPaths.isEmpty {
        VStack(alignment: .leading, spacing: 8) {
          HStack {
            Label("最近远端变更", systemImage: "arrow.down.doc")
              .font(.caption.weight(.semibold))
              .foregroundStyle(.secondary)
            Spacer()
            Text("在远端 diff 审阅中导入文章或复制 diff")
              .font(.caption2)
              .foregroundStyle(.tertiary)
          }

          ForEach(Array(store.repositoryAutoSyncState.remoteChangedPaths.prefix(5)), id: \.self) { path in
            HStack(spacing: 8) {
              Image(systemName: "doc.text.magnifyingglass")
                .foregroundStyle(.secondary)
                .frame(width: 16)
              Text(path)
                .font(.caption.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
              Spacer()
              Button {
                copy(path, message: "已复制自动同步发现的远端路径。")
              } label: {
                Label("复制路径", systemImage: "doc.on.doc")
              }
              .labelStyle(.iconOnly)
              .buttonStyle(.borderless)
              .help("复制远端路径")
              .accessibilityLabel("复制远端路径")
              .accessibilityValue(path)
            }
          }
        }
        .padding(10)
        .background(WorkbenchBackgroundStyle.panel, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
      }
    }
    .padding(14)
    .background(WorkbenchBackgroundStyle.card, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
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

  private var repositoryAutoSyncEnabledBinding: Binding<Bool> {
    Binding(
      get: { store.repositoryAutoSyncSettings.isEnabled },
      set: { isEnabled in
        store.updateRepositoryAutoSyncSettings(
          RepositoryAutoSyncSettings(
            isEnabled: isEnabled,
            intervalMinutes: store.repositoryAutoSyncSettings.normalizedIntervalMinutes,
            fetchBeforeScan: store.repositoryAutoSyncSettings.fetchBeforeScan
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
            fetchBeforeScan: fetchBeforeScan
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
            fetchBeforeScan: store.repositoryAutoSyncSettings.fetchBeforeScan
          )
        )
      }
    )
  }
}
