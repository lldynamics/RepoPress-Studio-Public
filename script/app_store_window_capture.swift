import CoreGraphics
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

private enum WindowCaptureError: LocalizedError {
  case invalidArguments
  case windowNotFound(CGWindowID, String)
  case destinationCreationFailed
  case encodingFailed

  var errorDescription: String? {
    switch self {
    case .invalidArguments:
      "usage: app-store-window-capture <window-id> <bundle-id> <output-png> [scale]"
    case .windowNotFound(let windowID, let bundleIdentifier):
      "window not found: \(windowID) for \(bundleIdentifier)"
    case .destinationCreationFailed:
      "could not create PNG destination"
    case .encodingFailed:
      "could not encode captured window"
    }
  }
}

@main
private struct AppStoreWindowCapture {
  static func main() async {
    do {
      let arguments = Array(CommandLine.arguments.dropFirst())
      guard arguments.count == 3 || arguments.count == 4,
            let rawWindowID = UInt32(arguments[0])
      else {
        throw WindowCaptureError.invalidArguments
      }
      let bundleIdentifier = arguments[1]
      let scale = arguments.count == 4 ? (Double(arguments[3]) ?? 2) : 2
      guard scale >= 1 else { throw WindowCaptureError.invalidArguments }

      let windowID = CGWindowID(rawWindowID)
      let content = try await SCShareableContent.excludingDesktopWindows(
        true,
        onScreenWindowsOnly: true
      )
      let applicationWindows = content.windows.filter { window in
        window.owningApplication?.bundleIdentifier == bundleIdentifier
          && window.frame.width >= 600
          && window.frame.height >= 500
      }
      guard let window = content.windows.first(where: { $0.windowID == windowID })
        ?? applicationWindows.first
      else {
        throw WindowCaptureError.windowNotFound(windowID, bundleIdentifier)
      }

      let filter = SCContentFilter(desktopIndependentWindow: window)
      let configuration = SCStreamConfiguration()
      configuration.width = max(Int((window.frame.width * scale).rounded()), 1)
      configuration.height = max(Int((window.frame.height * scale).rounded()), 1)
      configuration.showsCursor = false
      configuration.shouldBeOpaque = true

      let image = try await SCScreenshotManager.captureImage(
        contentFilter: filter,
        configuration: configuration
      )
      let outputURL = URL(fileURLWithPath: arguments[2])
      try FileManager.default.createDirectory(
        at: outputURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      guard let destination = CGImageDestinationCreateWithURL(
        outputURL as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil
      ) else {
        throw WindowCaptureError.destinationCreationFailed
      }
      CGImageDestinationAddImage(destination, image, nil)
      guard CGImageDestinationFinalize(destination) else {
        throw WindowCaptureError.encodingFailed
      }
      print("captured \(configuration.width)x\(configuration.height) window \(windowID)")
    } catch {
      FileHandle.standardError.write(Data("window capture failed: \(error.localizedDescription)\n".utf8))
      exit(1)
    }
  }
}
