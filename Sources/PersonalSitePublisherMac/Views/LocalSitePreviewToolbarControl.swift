import PublishingWorkbenchCore
import SwiftUI

struct LocalSitePreviewToolbarControl: View {
  @ObservedObject var store: WorkbenchStore
  let isCompact: Bool

  var body: some View {
    Menu {
      Section {
        Label(store.localSitePreviewRuntimeStatus.message, systemImage: statusSystemImage)

        if let previewURL {
          Text(previewURL.absoluteString)
            .font(.caption.monospaced())
        }
      } header: {
        Text("本地预览")
      }

      Divider()

      Toggle("启动本地预览", isOn: previewEnabled)
        .disabled(store.localSitePreviewPlan == nil && !store.localSitePreviewRuntimeStatus.isRunning)

      Button {
        guard let previewURL else { return }
        ExternalURLOpener.open(previewURL)
      } label: {
        Label("打开预览", systemImage: "safari")
      }
      .disabled(previewURL == nil || !store.localSitePreviewRuntimeStatus.isRunning)

      Button {
        Task {
          await store.verifyLocalSitePreviewReachability()
        }
      } label: {
        Label("检测端口", systemImage: "network")
      }
      .disabled(!store.localSitePreviewRuntimeStatus.isRunning)

      Divider()

      Button {
        store.selectSection(.sync)
      } label: {
        Label("查看本地预览详情", systemImage: "slider.horizontal.3")
      }
    } label: {
      HStack(spacing: 5) {
        Image(systemName: statusSystemImage)
          .foregroundStyle(statusColor)
        if !isCompact {
          Text(statusTitle)
            .foregroundStyle(.primary)
        }
      }
      .font(.caption2.weight(.semibold))
      .lineLimit(1)
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
    .help("本地预览：\(statusTitle)。\(store.localSitePreviewRuntimeStatus.message)")
    .accessibilityLabel("本地预览")
    .accessibilityValue(statusTitle)
    .task(id: store.activeProfileID) {
      store.refreshLocalSitePreviewRuntimeStatus()
      while !Task.isCancelled {
        do {
          try await Task.sleep(for: .seconds(3))
        } catch {
          return
        }
        store.refreshLocalSitePreviewRuntimeStatus()
      }
    }
  }

  private var previewEnabled: Binding<Bool> {
    Binding(
      get: { store.localSitePreviewRuntimeStatus.isRunning },
      set: { shouldRun in
        if shouldRun {
          store.startLocalSitePreview()
        } else {
          store.stopLocalSitePreview()
        }
      }
    )
  }

  private var previewURL: URL? {
    store.localSitePreviewRuntimeStatus.previewURL ?? store.localSitePreviewPlan?.previewURL
  }

  private var isTransitioning: Bool {
    let message = store.localSitePreviewRuntimeStatus.message
    return message.contains("正在停止") || message.contains("正在等待")
  }

  private var statusTitle: String {
    if store.localSitePreviewRuntimeStatus.isReachable {
      return String(localized: "预览可用")
    }
    if store.localSitePreviewRuntimeStatus.isRunning {
      return String(localized: "预览运行中")
    }
    if isTransitioning {
      return String(localized: "预览处理中")
    }
    if store.localSitePreviewPlan == nil {
      return String(localized: "预览未配置")
    }
    return String(localized: "预览已关闭")
  }

  private var statusSystemImage: String {
    if store.localSitePreviewRuntimeStatus.isReachable {
      return "checkmark.circle.fill"
    }
    if store.localSitePreviewRuntimeStatus.isRunning {
      return "play.circle.fill"
    }
    if isTransitioning {
      return "arrow.triangle.2.circlepath"
    }
    if store.localSitePreviewPlan == nil {
      return "questionmark.circle"
    }
    return "stop.circle"
  }

  private var statusColor: Color {
    if store.localSitePreviewRuntimeStatus.isReachable {
      return .green
    }
    if store.localSitePreviewRuntimeStatus.isRunning {
      return .blue
    }
    if isTransitioning {
      return .orange
    }
    return .secondary
  }
}
