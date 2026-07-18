import AppKit

enum ClipboardWriter {
  @discardableResult
  static func copy(
    _ value: String,
    successMessage: String,
    failureMessage: String = "复制失败，请重试。",
    setMessage: (String) -> Void
  ) -> Bool {
    NSPasteboard.general.clearContents()
    let didCopy = NSPasteboard.general.setString(value, forType: .string)
    setMessage(didCopy ? successMessage : failureMessage)
    return didCopy
  }
}
