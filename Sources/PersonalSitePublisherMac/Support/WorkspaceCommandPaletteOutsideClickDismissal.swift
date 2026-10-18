import AppKit
import SwiftUI

/// Keep both dismissal gestures on the palette's existing SwiftUI dismiss action.
struct WorkspaceCommandPaletteDismissal: ViewModifier {
  @Environment(\.dismiss) private var dismiss
  var isEnabled: Bool

  func body(content: Content) -> some View {
    content
      .background {
        WorkspaceCommandPaletteOutsideClickDismissal(isEnabled: isEnabled) {
          dismiss()
        }
      }
      .onExitCommand { dismiss() }
  }
}

/// Native sheets do not expose a SwiftUI backdrop gesture. Observe only clicks
/// in this palette's presenting window and consume the dismissal click.
struct WorkspaceCommandPaletteOutsideClickDismissal: NSViewRepresentable {
  var isEnabled: Bool
  var dismiss: () -> Void

  func makeNSView(context: Context) -> ObservationView {
    let view = ObservationView()
    view.update(isEnabled: isEnabled, dismiss: dismiss)
    return view
  }

  func updateNSView(_ view: ObservationView, context: Context) {
    view.update(isEnabled: isEnabled, dismiss: dismiss)
  }

  static func dismantleNSView(_ view: ObservationView, coordinator: ()) {
    view.stopMonitoring()
  }

  final class ObservationView: NSView {
    nonisolated(unsafe) private var monitor: Any?
    private var isEnabled = false
    private var dismiss: (() -> Void)?
    private var isDismissing = false

    var isMonitoring: Bool { monitor != nil }

    deinit {
      if let monitor { NSEvent.removeMonitor(monitor) }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      stopMonitoring()
      guard window != nil else { return }
      isDismissing = false
      monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
        [weak self] event in
        let consumed = MainActor.assumeIsolated {
          guard let self else { return false }
          return self.handleMouseDown(event) == nil
        }
        return consumed ? nil : event
      }
    }

    func update(isEnabled: Bool, dismiss: @escaping () -> Void) {
      self.isEnabled = isEnabled
      self.dismiss = dismiss
    }

    func stopMonitoring() {
      if let monitor { NSEvent.removeMonitor(monitor) }
      monitor = nil
    }

    func handleMouseDown(_ event: NSEvent) -> NSEvent? {
      guard isMonitoring, isEnabled, !isDismissing,
        event.type == .leftMouseDown || event.type == .rightMouseDown,
        let sheet = window, let parent = sheet.sheetParent,
        parent.attachedSheet === sheet, sheet.attachedSheet == nil,
        event.window === parent,
        !sheet.frame.contains(parent.convertPoint(toScreen: event.locationInWindow))
      else { return event }
      isDismissing = true
      dismiss?()
      return nil
    }
  }
}
