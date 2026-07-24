import AppKit
import Foundation
import PublishingWorkbenchCore

enum ExternalURLOpener {
  @discardableResult
  static func open(
    _ url: URL,
    failureMessage: String = "无法打开链接。",
    report: ((String) -> Void)? = nil
  ) -> Bool {
    guard let validatedURL = ExternalWebURLPolicy.validatedURL(url) else {
      report?(String(localized: "仅支持打开不含凭据的 HTTP 或 HTTPS 链接。"))
      return false
    }
    let didOpen = NSWorkspace.shared.open(validatedURL)
    if !didOpen {
      report?(failureMessage)
    }
    return didOpen
  }
}
