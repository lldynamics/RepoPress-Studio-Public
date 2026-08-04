import CoreGraphics
import Foundation

private func fail(_ message: String, code: Int32) -> Never {
  FileHandle.standardError.write(Data((message + "\n").utf8))
  exit(code)
}

guard CommandLine.arguments.count == 3,
      let targetPID = Int32(CommandLine.arguments[1]),
      let timeoutSeconds = Double(CommandLine.arguments[2]),
      timeoutSeconds > 0 else {
  fail(
    "usage: window_visibility_probe <pid> <timeout-seconds>",
    code: 2
  )
}

let deadline = Date().addingTimeInterval(timeoutSeconds)
repeat {
  guard let windows = CGWindowListCopyWindowInfo(
    [.optionOnScreenOnly, .excludeDesktopElements],
    kCGNullWindowID
  ) as? [[String: Any]] else {
    fail("window visibility probe could not read the on-screen window list", code: 2)
  }

  let hasVisibleMainWindow = windows.contains { window in
    guard (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == targetPID,
          (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
          (window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 0 > 0,
          let bounds = window[kCGWindowBounds as String] as? NSDictionary,
          let frame = CGRect(dictionaryRepresentation: bounds),
          frame.width >= 100,
          frame.height >= 100 else {
      return false
    }
    return true
  }

  if hasVisibleMainWindow {
    exit(0)
  }
  Thread.sleep(forTimeInterval: 0.05)
} while Date() < deadline

fail("target process did not expose an on-screen main window", code: 1)
