import AppKit
import Foundation

enum ExternalURLOpener {
  @discardableResult
  static func open(
    _ url: URL,
    failureMessage: String = "无法打开链接。",
    report: ((String) -> Void)? = nil
  ) -> Bool {
    let didOpen = NSWorkspace.shared.open(url)
    if !didOpen {
      report?(failureMessage)
    }
    return didOpen
  }
}
