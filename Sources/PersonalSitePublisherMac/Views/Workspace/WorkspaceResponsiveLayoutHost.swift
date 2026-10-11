import AppKit
import SwiftUI

/// Measure the owning window so native Inspector animation cannot feed its
/// temporary container geometry back into the workspace's layout policy.
struct WorkspaceResponsiveLayoutHost<Content: View>: View {
  let content: Content
  let onChange: (WorkspaceResponsiveLayoutSnapshot) -> Void

  init(
    onChange: @escaping (WorkspaceResponsiveLayoutSnapshot) -> Void,
    @ViewBuilder content: () -> Content
  ) {
    self.content = content()
    self.onChange = onChange
  }

  var body: some View {
    content
      .background {
        WorkspaceWindowWidthBridge(onChange: onChange)
          .allowsHitTesting(false)
      }
  }
}

struct WorkspaceWindowWidthBridge: NSViewRepresentable {
  let onChange: (WorkspaceResponsiveLayoutSnapshot) -> Void

  func makeNSView(context: Context) -> WindowWidthObservationView {
    let view = WindowWidthObservationView()
    view.update(onChange: onChange)
    return view
  }

  func updateNSView(_ view: WindowWidthObservationView, context: Context) {
    view.update(onChange: onChange)
  }

  static func dismantleNSView(_ view: WindowWidthObservationView, coordinator: ()) {
    view.stopObservingWindow()
  }

  final class WindowWidthObservationView: NSView {
    private var onChange: ((WorkspaceResponsiveLayoutSnapshot) -> Void)?
    private weak var observedWindow: NSWindow?
    private var observationGeneration: UInt = 0
    private var lastDeliveredSnapshot: WorkspaceResponsiveLayoutSnapshot?
    private var pendingSnapshot: WorkspaceResponsiveLayoutSnapshot?
    private var isDeliveryScheduled = false

    deinit {
      NotificationCenter.default.removeObserver(self)
    }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      refreshWindowObservation()
    }

    func update(onChange: @escaping (WorkspaceResponsiveLayoutSnapshot) -> Void) {
      self.onChange = onChange
      refreshWindowObservation()
    }

    func stopObservingWindow() {
      NotificationCenter.default.removeObserver(
        self, name: NSWindow.didResizeNotification, object: observedWindow
      )
      observedWindow = nil
      observationGeneration &+= 1
      lastDeliveredSnapshot = nil
      pendingSnapshot = nil
      isDeliveryScheduled = false
    }

    private func refreshWindowObservation() {
      if observedWindow !== window {
        stopObservingWindow()
        observedWindow = window
        if let observedWindow {
          NotificationCenter.default.addObserver(
            self,
            selector: #selector(owningWindowDidResize(_:)),
            name: NSWindow.didResizeNotification,
            object: observedWindow
          )
        }
      }
      guard let observedWindow else { return }
      scheduleSnapshot(from: observedWindow)
    }

    @objc private func owningWindowDidResize(_ notification: Notification) {
      guard let observedWindow,
        notification.object as? NSWindow === observedWindow,
        window === observedWindow
      else { return }
      scheduleSnapshot(from: observedWindow)
    }

    private func scheduleSnapshot(from window: NSWindow) {
      let width = window.contentLayoutRect.size.width
      guard width.isFinite, width > 0 else {
        pendingSnapshot = nil
        return
      }
      let snapshot = WorkspaceResponsiveLayoutSnapshot(width: width)
      guard snapshot != lastDeliveredSnapshot || pendingSnapshot != nil else { return }
      pendingSnapshot = snapshot
      guard !isDeliveryScheduled else { return }
      isDeliveryScheduled = true
      let generation = observationGeneration

      // Keep state writes out of SwiftUI's native-view update, including while
      // AppKit tracks a live resize in its event-tracking run-loop mode.
      RunLoop.main.perform(inModes: [.default, RunLoop.Mode("NSEventTrackingRunLoopMode")]) {
        [weak self, weak window] in
        MainActor.assumeIsolated {
          guard let self, let window,
            self.observationGeneration == generation,
            self.observedWindow === window,
            self.window === window
          else { return }
          self.isDeliveryScheduled = false
          guard let snapshot = self.pendingSnapshot else { return }
          self.pendingSnapshot = nil
          guard snapshot != self.lastDeliveredSnapshot else { return }
          self.lastDeliveredSnapshot = snapshot
          self.onChange?(snapshot)
        }
      }
    }
  }
}
