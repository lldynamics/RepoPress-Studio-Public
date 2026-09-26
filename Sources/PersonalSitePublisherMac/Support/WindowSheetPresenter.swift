import AppKit

@MainActor
enum WindowSheetPresenter {
  private static var presentingWindow: NSWindow? {
    [NSApp.keyWindow, NSApp.mainWindow]
      .compactMap { $0 }
      .first { $0.isVisible && $0.attachedSheet == nil }
  }

  static func response(to alert: NSAlert, in window: NSWindow? = nil) async
    -> NSApplication.ModalResponse
  {
    return await withCheckedContinuation { continuation in
      if let window = window ?? presentingWindow {
        alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
      } else {
        continuation.resume(returning: alert.runModal())
      }
    }
  }

  static func response(to panel: NSSavePanel, in window: NSWindow? = nil) async
    -> NSApplication.ModalResponse
  {
    return await withCheckedContinuation { continuation in
      if let window = window ?? presentingWindow {
        panel.beginSheetModal(for: window) { continuation.resume(returning: $0) }
      } else {
        panel.begin { continuation.resume(returning: $0) }
      }
    }
  }
}
