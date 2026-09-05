import AppKit
import SwiftUI

/// The composed search button needs a custom-view toolbar item. An explicit
/// AppKit host prevents the native toolbar's button extraction from dropping
/// its HStack label, and gives the toolbar a stable fitting size at insertion.
struct WorkspaceCommandSearchNativeHost: NSViewRepresentable {
  let density: WorkspaceTopBarPresentation.Density
  let statistics: WorkspaceTopBarPresentation.ContextStatistics
  let isEnabled: Bool
  let action: () -> Void

  private var content: WorkspaceCommandSearchHostedContent {
    WorkspaceCommandSearchHostedContent(
      density: density, statistics: statistics, isEnabled: isEnabled, action: action
    )
  }

  private var fittingSize: NSSize {
    NSSize(width: WorkspaceTopBarPresentation.searchWidth(for: density), height: 28)
  }

  func makeNSView(context: Context) -> NSHostingView<WorkspaceCommandSearchHostedContent> {
    let host = NSHostingView(rootView: content)
    host.sizingOptions = [.intrinsicContentSize]
    host.setFrameSize(fittingSize)
    return host
  }

  func updateNSView(_ host: NSHostingView<WorkspaceCommandSearchHostedContent>, context: Context) {
    host.rootView = content
    host.setFrameSize(fittingSize)
    host.invalidateIntrinsicContentSize()
  }

  func sizeThatFits(
    _ proposal: ProposedViewSize,
    nsView: NSHostingView<WorkspaceCommandSearchHostedContent>,
    context: Context
  ) -> CGSize? {
    fittingSize
  }
}

struct WorkspaceCommandSearchHostedContent: View {
  let density: WorkspaceTopBarPresentation.Density
  let statistics: WorkspaceTopBarPresentation.ContextStatistics
  let isEnabled: Bool
  let action: () -> Void

  var body: some View {
    OmniCommandSearchBar(density: density, statistics: statistics, action: action)
      .disabled(!isEnabled)
      .frame(width: WorkspaceTopBarPresentation.searchWidth(for: density), height: 28)
  }
}
