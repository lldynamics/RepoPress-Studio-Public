import AppKit
import Foundation
import PublishingWorkbenchCore
import WebKit
import XCTest

@testable import PersonalSitePublisherMac

@MainActor
final class P3AppKitAcceptanceTests: XCTestCase {
  func testAppKitPasteOverrideRoutesTheGeneralPasteboardThroughSmartPaste() {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString("https://example.com/article", forType: .string)
    defer { NSPasteboard.general.clearContents() }
    let textView = DroppableMarkdownTextView(
      frame: NSRect(x: 0, y: 0, width: 320, height: 180),
      textContainer: nil
    )
    textView.string = "Existing draft"
    var receivedText: String?
    textView.smartPasteHandler = { _, pasteboard in
      receivedText = pasteboard.string(forType: .string)
      return true
    }

    textView.paste(nil)

    XCTAssertEqual(receivedText, "https://example.com/article")
  }

  func testStoppingAnActiveAssetTransferSuppressesAllLaterCallbacks() async throws {
    let fixture = try makeFixture(byteCount: 16 * 1_024 * 1_024)
    defer { try? FileManager.default.removeItem(at: fixture.directoryURL) }
    let attachmentID = UUID()
    let requestURL = try XCTUnwrap(
      URL(
        string:
          "\(MarkdownPreviewAssetService.URLScheme)://attachment/\(attachmentID.uuidString.lowercased())"
      )
    )
    let firstData = expectation(description: "the transfer starts")
    let callbackAfterStop = expectation(description: "no callbacks after stop")
    callbackAfterStop.isInverted = true
    let task = ActiveTransferSchemeTask(
      request: URLRequest(url: requestURL),
      firstData: firstData,
      callbackAfterStop: callbackAfterStop
    )
    let handler = MarkdownPreviewAssetSchemeHandler()
    handler.update(resources: [
      MarkdownPreviewAssetResource(
        attachmentID: attachmentID,
        sourceURL: fixture.fileURL,
        mimeType: "image/jpeg",
        previewURLString: requestURL.absoluteString
      )
    ])
    let webView = WKWebView()

    handler.webView(webView, start: task)
    await fulfillment(of: [firstData], timeout: 2)
    handler.webView(webView, stop: task)
    task.markStopped()
    await fulfillment(of: [callbackAfterStop], timeout: 0.25)
  }

  private func makeFixture(
    byteCount: Int
  ) throws -> (directoryURL: URL, fileURL: URL) {
    let directoryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "P3ActiveAssetCancellation-\(UUID().uuidString)",
        isDirectory: true
      )
    try FileManager.default.createDirectory(
      at: directoryURL,
      withIntermediateDirectories: true
    )
    let fileURL = directoryURL.appendingPathComponent("asset.bin")
    try Data(repeating: 0xA5, count: byteCount).write(to: fileURL)
    return (directoryURL, fileURL)
  }
}

private final class ActiveTransferSchemeTask: NSObject, WKURLSchemeTask {
  let request: URLRequest

  private let lock = NSLock()
  private let firstDataExpectation: XCTestExpectation
  private let callbackAfterStopExpectation: XCTestExpectation
  private var didReceiveFirstData = false
  private var isStopped = false

  init(
    request: URLRequest,
    firstData: XCTestExpectation,
    callbackAfterStop: XCTestExpectation
  ) {
    self.request = request
    firstDataExpectation = firstData
    callbackAfterStopExpectation = callbackAfterStop
  }

  func didReceive(_ response: URLResponse) {
    reportCallbackAfterStopIfNeeded()
  }

  func didReceive(_ data: Data) {
    lock.lock()
    let shouldFulfillFirstData = !didReceiveFirstData
    didReceiveFirstData = true
    let callbackAfterStop = isStopped
    lock.unlock()
    if shouldFulfillFirstData {
      firstDataExpectation.fulfill()
    }
    if callbackAfterStop {
      callbackAfterStopExpectation.fulfill()
    }
  }

  func didFinish() {
    reportCallbackAfterStopIfNeeded()
  }

  func didFailWithError(_ error: Error) {
    reportCallbackAfterStopIfNeeded()
  }

  func markStopped() {
    lock.lock()
    isStopped = true
    lock.unlock()
  }

  private func reportCallbackAfterStopIfNeeded() {
    lock.lock()
    let callbackAfterStop = isStopped
    lock.unlock()
    if callbackAfterStop {
      callbackAfterStopExpectation.fulfill()
    }
  }
}
