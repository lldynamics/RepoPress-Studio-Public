import PublishingWorkbenchCore
import SwiftUI

struct WorkspacePublishDrawerLayoutPolicy {
  static let minimumWidth: CGFloat = 380
  static let idealWidth: CGFloat = 500
  static let availableWidthRatio: CGFloat = 0.45

  static func width(for availableWidth: CGFloat) -> CGFloat {
    let nonnegativeWidth = max(0, availableWidth)
    let proposedWidth = min(
      idealWidth,
      max(minimumWidth, nonnegativeWidth * availableWidthRatio)
    )
    return min(proposedWidth, nonnegativeWidth)
  }
}

/// Publishing is presented above the workspace rather than as a native
/// inspector column. A native inspector participates in split-view sizing and
/// compresses the source list; this trailing overlay leaves the established
/// sidebar and editor widths untouched while the user reviews the publish flow.
struct WorkspacePublishDrawerOverlay: View {
  @ObservedObject var publishingFacade: WorkbenchPublishingFeatureFacade
  let store: WorkbenchStore
  @Binding var isPresented: Bool
  let initialScope: PublishScope
  let onNavigateIssue: (UUID, PublishReadinessTarget) -> Void

  var body: some View {
    GeometryReader { geometry in
      HStack(spacing: 0) {
        Spacer(minLength: 0)

        Divider()

        PublishDrawerView(
          publishingFacade: publishingFacade,
          store: store,
          isPresented: $isPresented,
          initialScope: initialScope,
          onNavigateIssue: onNavigateIssue
        )
        .frame(width: WorkspacePublishDrawerLayoutPolicy.width(for: geometry.size.width))
        .frame(maxHeight: .infinity)
        .background(.regularMaterial)
        .shadow(color: .black.opacity(0.16), radius: 18, x: -6, y: 0)
      }
    }
    .accessibilityIdentifier("workspace-publish-drawer-overlay")
  }
}
