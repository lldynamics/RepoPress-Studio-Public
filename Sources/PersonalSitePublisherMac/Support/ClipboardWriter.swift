import AppKit
import PublishingWorkbenchCore

enum ClipboardWriter {
  @discardableResult
  static func copy(
    _ value: String,
    successMessage: String,
    failureMessage: String = String(localized: "复制失败，请重试。"),
    setMessage: (String, PublishActionMessageStatus) -> Void
  ) -> Bool {
    NSPasteboard.general.clearContents()
    let didCopy = NSPasteboard.general.setString(value, forType: .string)
    setMessage(
      didCopy
        ? String(localized: String.LocalizationValue(successMessage))
        : String(localized: String.LocalizationValue(failureMessage)),
      didCopy ? .success : .failure
    )
    return didCopy
  }

  @discardableResult
  static func copy(
    _ value: String,
    successMessage: String,
    failureMessage: String = String(localized: "复制失败，请重试。"),
    setMessage: (String) -> Void
  ) -> Bool {
    copy(
      value,
      successMessage: successMessage,
      failureMessage: failureMessage
    ) { message, _ in
      setMessage(message)
    }
  }
}
