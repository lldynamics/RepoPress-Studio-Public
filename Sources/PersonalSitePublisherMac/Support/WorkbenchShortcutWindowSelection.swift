import AppKit

/// The window that receives a shortcut also stays in front after activation.
@MainActor
final class WorkbenchShortcutWindowSelection {
  static let shared = WorkbenchShortcutWindowSelection()
  private weak var lastActiveWindow: NSWindow?

  func record(_ window: NSWindow) { lastActiveWindow = window }

  func preferredWindow(in windows: [NSWindow]) -> NSWindow? {
    if let key = windows.first(where: \.isKeyWindow) { return key }
    if let lastActiveWindow, windows.contains(where: { $0 === lastActiveWindow }) {
      return lastActiveWindow
    }
    return windows.first(where: \.isMainWindow) ?? windows.first
  }
}
