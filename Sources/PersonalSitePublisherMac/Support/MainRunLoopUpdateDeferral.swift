import Foundation

enum MainRunLoopUpdateDeferral {
  @MainActor
  static func waitForNextDefaultModeCycle() async {
    await withCheckedContinuation { continuation in
      RunLoop.main.perform(inModes: [.default]) {
        continuation.resume()
      }
    }
  }
}
