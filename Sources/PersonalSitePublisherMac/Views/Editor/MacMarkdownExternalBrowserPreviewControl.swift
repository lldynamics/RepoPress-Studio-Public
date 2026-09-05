import PublishingWorkbenchCore
import SwiftUI

struct MacMarkdownExternalBrowserPreviewControl: View {
  let store: WorkbenchStore
  let draftID: UUID
  let showsTitle: Bool
  @ObservedObject var coordinator: ExternalBrowserPreviewCoordinator

  @EnvironmentObject private var localPreviewState: WorkbenchLocalSitePreviewFeatureFacade
  @State private var isManagementPopoverPresented = false

  var body: some View {
    Menu {
      Button {
        coordinator.openCurrentArticle(for: draftID)
      } label: {
        Label("打开当前文章", systemImage: "doc.text.magnifyingglass")
      }
      .disabled(coordinator.isBusy)

      Button {
        coordinator.openSiteHome(for: draftID)
      } label: {
        Label("打开站点首页", systemImage: "house")
      }
      .disabled(coordinator.isBusy)

      Divider()

      Button {
        isManagementPopoverPresented = true
      } label: {
        Label("管理本地预览", systemImage: "slider.horizontal.3")
      }

      Button(role: .destructive) {
        coordinator.cancelPendingOpen()
        localPreviewState.stop()
      } label: {
        Label("停止本地预览", systemImage: "stop.circle")
      }
      .disabled(!localPreviewState.runtimeStatus.isRunning)
    } label: {
      previewLabel
    } primaryAction: {
      coordinator.openCurrentArticle(for: draftID)
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .buttonStyle(MarkdownEditorToolbarButtonStyle(showsTitle: showsTitle))
    .help(helpText)
    .accessibilityLabel(String(localized: "在浏览器中预览当前文章"))
    .accessibilityValue(accessibilityValue)
    .accessibilityIdentifier("markdown-external-browser-preview")
    .popover(isPresented: $isManagementPopoverPresented, arrowEdge: .top) {
      MacMarkdownLocalPreviewPopover(
        draftID: draftID,
        coordinator: coordinator
      )
    }
    .externalBrowserPreviewPresentation(coordinator: coordinator)
    .onChange(of: localPreviewState.activeProfileID) {
      coordinator.cancelPendingOpen()
    }
    .onChange(of: draftID) { _, draftID in
      coordinator.cancelPendingOpen(ifDraftIsNoLongerCurrent: draftID)
    }
    .onDisappear {
      coordinator.cancelPendingOpen()
    }
  }
}

private struct ExternalBrowserPreviewPresentationModifier: ViewModifier {
  @ObservedObject var coordinator: ExternalBrowserPreviewCoordinator

  func body(content: Content) -> some View {
    content
      .sheet(
        item: Binding(
          get: { coordinator.pendingAuthorizationRequest },
          set: { request in
            if request == nil, coordinator.pendingAuthorizationRequest != nil {
              coordinator.cancelPendingOpen()
            }
          }
        )
      ) { request in
        LocalSitePreviewTrustConfirmationView(
          request: request,
          entryPoint: .externalBrowser,
          cancelAction: {
            coordinator.cancelPendingOpen()
          },
          confirmAction: {
            coordinator.authorizeAndContinue(request)
          }
        )
      }
      .alert(
        String(localized: "无法打开本地预览"),
        isPresented: Binding(
          get: { coordinator.errorMessage != nil },
          set: { isPresented in
            if !isPresented {
              coordinator.dismissError()
            }
          }
        ),
        actions: {
          Button(String(localized: "好"), role: .cancel) {
            coordinator.dismissError()
          }
        },
        message: {
          Text(coordinator.errorMessage ?? "")
        }
      )
  }
}

extension View {
  func externalBrowserPreviewPresentation(
    coordinator: ExternalBrowserPreviewCoordinator
  ) -> some View {
    modifier(ExternalBrowserPreviewPresentationModifier(coordinator: coordinator))
  }
}

extension MacMarkdownExternalBrowserPreviewControl {

  @ViewBuilder
  private var previewLabel: some View {
    let title = localPreviewState.runtimeStatus.isRunning ? "打开预览" : "浏览器预览"
    let systemName =
      coordinator.isBusy
      ? "hourglass"
      : (localPreviewState.runtimeStatus.isRunning ? "safari" : "play.rectangle")
    if showsTitle {
      Label(title, systemImage: systemName)
    } else {
      Image(systemName: systemName)
        .accessibilityHidden(true)
    }
  }

  private var helpText: String {
    coordinator.isBusy
      ? String(localized: "正在准备浏览器预览")
      : String(localized: "在系统浏览器中打开当前文章；按住可打开菜单")
  }

  private var accessibilityValue: String {
    if let message = coordinator.message, !message.isEmpty {
      return message
    }
    if localPreviewState.runtimeStatus.isRunning {
      return String(localized: "本地预览正在运行")
    }
    return localPreviewState.plan?.diagnostics.isReadyToStart == true
      ? String(localized: "可以启动")
      : String(localized: "需要先配置站点仓库")
  }
}
