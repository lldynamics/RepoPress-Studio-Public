import CoreGraphics
import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 1 || (arguments.count == 2 && arguments[1] == "--debug") else {
  FileHandle.standardError.write(Data("usage: app_store_window_id.swift <pid> [--debug]\n".utf8))
  exit(2)
}

guard let processIdentifier = Int(arguments[0]), processIdentifier > 0 else {
  exit(1)
}
let debug = arguments.count == 2
let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
  exit(1)
}

for window in windows {
  let rawOwnerPID = window[kCGWindowOwnerPID as String]
  let ownerPID = (rawOwnerPID as? NSNumber)?.intValue ?? (rawOwnerPID as? Int)
  guard ownerPID == processIdentifier else { continue }
  if debug {
    print(
      "pid=\(ownerPID ?? -1) layer=\(String(describing: window[kCGWindowLayer as String])) " +
        "number=\(String(describing: window[kCGWindowNumber as String])) " +
        "bounds=\(String(describing: window[kCGWindowBounds as String]))"
    )
  }
  guard let layer = (window[kCGWindowLayer as String] as? NSNumber)?.intValue,
        layer == 0,
        let number = (window[kCGWindowNumber as String] as? NSNumber)?.intValue,
        let bounds = window[kCGWindowBounds as String] as? [String: NSNumber],
        let width = bounds["Width"]?.doubleValue,
        let height = bounds["Height"]?.doubleValue,
        width >= 600,
        height >= 500
  else {
    continue
  }
  print(number)
  exit(0)
}

exit(debug ? 0 : 1)
