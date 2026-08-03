import PublishingWorkbenchCore
import SwiftUI

struct LocalSitePreviewToolbarControl: View {
  @StateObject private var state: WorkbenchLocalSitePreviewFeatureFacade
  @Environment(\.localSitePreviewCommandAction) private var localSitePreviewCommandAction
  let isCompact: Bool

  init(store: WorkbenchStore, isCompact: Bool) {
    _state = StateObject(
      wrappedValue: WorkbenchLocalSitePreviewFeatureFacade(store: store)
    )
    self.isCompact = isCompact
  }

  var body: some View {
    Menu {
      Section {
        Label(state.runtimeStatus.message, systemImage: statusSystemImage)

        if let previewURL {
          Text(previewURL.absoluteString)
            .font(.caption.monospaced())
        }
      } header: {
        Text("本地预览")
      }

      Divider()

      Toggle("启动本地预览", isOn: previewEnabled)
        .disabled(state.plan == nil && !state.runtimeStatus.isRunning)

      Button {
        localSitePreviewCommandAction?.open()
      } label: {
        Label("在应用内预览", systemImage: "rectangle.inset.filled")
      }
      .disabled(localSitePreviewCommandAction == nil || state.plan == nil)

      Button {
        guard let previewURL else { return }
        ExternalURLOpener.open(previewURL)
      } label: {
        Label("在浏览器中打开", systemImage: "safari")
      }
      .disabled(previewURL == nil || !state.runtimeStatus.isRunning)

      Button {
        Task {
          await state.verifyReachability()
        }
      } label: {
        Label("检查预览连接", systemImage: "network")
      }
      .disabled(!state.runtimeStatus.isRunning)

      Divider()

      Button {
        state.openSettings()
      } label: {
        Label("预览设置与详情", systemImage: "slider.horizontal.3")
      }
    } label: {
      WorkspaceToolbarMenuLabel(
        title: "预览",
        systemImage: statusSystemImage,
        showsTitle: !isCompact,
        iconColor: statusColor
      )
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
    .help(String(localized: "本地预览：\(statusTitle)。\(state.runtimeStatus.message)"))
    .accessibilityLabel("本地预览")
    .accessibilityValue(statusTitle)
    .accessibilityIdentifier("workspace-preview-menu")
    .task(id: state.activeProfileID) {
      state.refreshStatus()
      while !Task.isCancelled {
        do {
          try await Task.sleep(for: .seconds(3))
        } catch {
          return
        }
        state.refreshStatus()
      }
    }
  }

  private var previewEnabled: Binding<Bool> {
    Binding(
      get: { state.runtimeStatus.isRunning },
      set: { shouldRun in
        if shouldRun {
          state.start()
        } else {
          state.stop()
        }
      }
    )
  }

  private var previewURL: URL? {
    state.runtimeStatus.previewURL ?? state.plan?.previewURL
  }

  private var isTransitioning: Bool {
    let message = state.runtimeStatus.message
    return message.contains("正在停止") || message.contains("正在等待")
  }

  private var statusTitle: String {
    if state.runtimeStatus.isReachable {
      return String(localized: "预览可用")
    }
    if state.runtimeStatus.isRunning {
      return String(localized: "预览运行中")
    }
    if isTransitioning {
      return String(localized: "预览处理中")
    }
    if state.plan == nil {
      return String(localized: "预览未配置")
    }
    return String(localized: "预览已关闭")
  }

  private var statusSystemImage: String {
    if state.runtimeStatus.isReachable {
      return "checkmark.circle.fill"
    }
    if state.runtimeStatus.isRunning {
      return "play.circle.fill"
    }
    if isTransitioning {
      return "arrow.triangle.2.circlepath"
    }
    if state.plan == nil {
      return "questionmark.circle"
    }
    return "stop.circle"
  }

  private var statusColor: Color {
    if state.runtimeStatus.isReachable {
      return WorkbenchTheme.success
    }
    if state.runtimeStatus.isRunning {
      return WorkbenchTheme.progress
    }
    if isTransitioning {
      return WorkbenchTheme.warning
    }
    return .secondary
  }
}
