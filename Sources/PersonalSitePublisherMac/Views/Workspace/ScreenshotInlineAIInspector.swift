import PublishingWorkbenchCore
import SwiftUI

#if DEBUG || SCREENSHOT_CAPTURE_BUILD
  struct ScreenshotInlineAIInspector: View {
    let store: WorkbenchStore
    @State private var surfaceState = AIChatSurfaceState(surface: .inspector)
    @StateObject private var operationSession = AIChatSurfaceOperationSession()

    var body: some View {
      GeometryReader { geometry in
        HStack(spacing: 0) {
          Spacer(minLength: 0)
          Divider()
          AIChatContextInspectorView(
            store: store,
            surfaceState: $surfaceState,
            operationSession: operationSession
          )
          .frame(width: min(max(geometry.size.width * 0.38, 460), 520))
          .frame(maxHeight: .infinity)
          .background(Color(nsColor: .windowBackgroundColor))
        }
      }
    }
  }
#endif
