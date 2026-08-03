import Foundation
import PublishingWorkbenchCore
import WebKit
import XCTest

@testable import PersonalSitePublisherMac

final class MarkdownPreviewAssetSchemeHandlerTests: XCTestCase {
  func testByteRangeResolutionSupportsOpenEndedAndSuffixRanges() throws {
    XCTAssertEqual(
      try MarkdownPreviewAssetByteRange.resolve(header: "bytes=10-19", fileSize: 100),
      MarkdownPreviewAssetByteRange(lowerBound: 10, upperBound: 19)
    )
    XCTAssertEqual(
      try MarkdownPreviewAssetByteRange.resolve(header: "bytes=90-", fileSize: 100),
      MarkdownPreviewAssetByteRange(lowerBound: 90, upperBound: 99)
    )
    XCTAssertEqual(
      try MarkdownPreviewAssetByteRange.resolve(header: "bytes=-8", fileSize: 100),
      MarkdownPreviewAssetByteRange(lowerBound: 92, upperBound: 99)
    )
    XCTAssertEqual(
      try MarkdownPreviewAssetByteRange.resolve(header: "bytes=95-500", fileSize: 100),
      MarkdownPreviewAssetByteRange(lowerBound: 95, upperBound: 99)
    )
    XCTAssertNil(try MarkdownPreviewAssetByteRange.resolve(header: nil, fileSize: 100))
    XCTAssertThrowsError(
      try MarkdownPreviewAssetByteRange.resolve(header: "bytes=100-101", fileSize: 100)
    )
    XCTAssertThrowsError(
      try MarkdownPreviewAssetByteRange.resolve(header: "bytes=1-2,4-5", fileSize: 100)
    )
  }

  @MainActor
  func testVideoRangeRequestStreamsOnlyRequestedBytes() async throws {
    let fixture = try makeFixture(byteCount: 200_000)
    defer { try? FileManager.default.removeItem(at: fixture.directoryURL) }
    let attachmentID = UUID()
    let requestURL = try XCTUnwrap(
      URL(
        string:
          "\(MarkdownPreviewAssetService.URLScheme)://attachment/\(attachmentID.uuidString.lowercased())"
      ))
    var request = URLRequest(url: requestURL)
    request.setValue("bytes=65-130", forHTTPHeaderField: "Range")
    let didFinish = expectation(description: "range request finishes")
    let task = MockURLSchemeTask(request: request, didFinish: didFinish)
    let handler = MarkdownPreviewAssetSchemeHandler()
    handler.update(resources: [
      MarkdownPreviewAssetResource(
        attachmentID: attachmentID,
        sourceURL: fixture.fileURL,
        mimeType: "video/mp4",
        previewURLString: requestURL.absoluteString
      )
    ])

    handler.webView(WKWebView(), start: task)
    await fulfillment(of: [didFinish], timeout: 2)

    let snapshot = task.snapshot()
    let response = try XCTUnwrap(snapshot.response as? HTTPURLResponse)
    XCTAssertEqual(response.statusCode, 206)
    XCTAssertEqual(response.value(forHTTPHeaderField: "Content-Range"), "bytes 65-130/200000")
    XCTAssertEqual(snapshot.data, fixture.data.subdata(in: 65..<131))
    XCTAssertNil(snapshot.error)
  }

  @MainActor
  func testFullAssetIsDeliveredInBoundedChunks() async throws {
    let fixture = try makeFixture(byteCount: 200_000)
    defer { try? FileManager.default.removeItem(at: fixture.directoryURL) }
    let attachmentID = UUID()
    let requestURL = try XCTUnwrap(
      URL(
        string:
          "\(MarkdownPreviewAssetService.URLScheme)://attachment/\(attachmentID.uuidString.lowercased())"
      ))
    let didFinish = expectation(description: "full request finishes")
    let task = MockURLSchemeTask(
      request: URLRequest(url: requestURL),
      didFinish: didFinish
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

    handler.webView(WKWebView(), start: task)
    await fulfillment(of: [didFinish], timeout: 2)

    let snapshot = task.snapshot()
    XCTAssertEqual(snapshot.data, fixture.data)
    XCTAssertGreaterThan(snapshot.chunkSizes.count, 1)
    XCTAssertLessThanOrEqual(snapshot.chunkSizes.max() ?? 0, 64 * 1_024)
    XCTAssertNil(snapshot.error)
  }

  @MainActor
  func testStopPreventsCallbacksAfterCancellationReturns() async throws {
    let fixture = try makeFixture(byteCount: 8 * 1_024 * 1_024)
    defer { try? FileManager.default.removeItem(at: fixture.directoryURL) }
    let attachmentID = UUID()
    let requestURL = try XCTUnwrap(
      URL(
        string:
          "\(MarkdownPreviewAssetService.URLScheme)://attachment/\(attachmentID.uuidString.lowercased())"
      ))
    let callbackAfterStop = expectation(description: "no callbacks after stop")
    callbackAfterStop.isInverted = true
    let task = MockURLSchemeTask(
      request: URLRequest(url: requestURL),
      didFinish: nil,
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
    handler.webView(webView, stop: task)
    task.markStopped()
    await fulfillment(of: [callbackAfterStop], timeout: 0.2)
  }

  private func makeFixture(
    byteCount: Int
  ) throws -> (directoryURL: URL, fileURL: URL, data: Data) {
    let directoryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("MarkdownPreviewAssetTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    let fileURL = directoryURL.appendingPathComponent("asset.bin")
    let data = Data(repeating: 0x5A, count: byteCount)
    try data.write(to: fileURL)
    return (directoryURL, fileURL, data)
  }
}

private final class MockURLSchemeTask: NSObject, WKURLSchemeTask {
  let request: URLRequest

  private let lock = NSLock()
  private let didFinishExpectation: XCTestExpectation?
  private let callbackAfterStopExpectation: XCTestExpectation?
  private var responseStorage: URLResponse?
  private var dataStorage = Data()
  private var chunkSizesStorage: [Int] = []
  private var errorStorage: Error?
  private var isStopped = false

  init(
    request: URLRequest,
    didFinish: XCTestExpectation?,
    callbackAfterStop: XCTestExpectation? = nil
  ) {
    self.request = request
    self.didFinishExpectation = didFinish
    self.callbackAfterStopExpectation = callbackAfterStop
  }

  func didReceive(_ response: URLResponse) {
    lock.lock()
    let callbackAfterStop = isStopped
    responseStorage = response
    lock.unlock()
    if callbackAfterStop {
      callbackAfterStopExpectation?.fulfill()
    }
  }

  func didReceive(_ data: Data) {
    lock.lock()
    let callbackAfterStop = isStopped
    dataStorage.append(data)
    chunkSizesStorage.append(data.count)
    lock.unlock()
    if callbackAfterStop {
      callbackAfterStopExpectation?.fulfill()
    }
  }

  func didFinish() {
    lock.lock()
    let callbackAfterStop = isStopped
    lock.unlock()
    if callbackAfterStop {
      callbackAfterStopExpectation?.fulfill()
    }
    didFinishExpectation?.fulfill()
  }

  func didFailWithError(_ error: Error) {
    lock.lock()
    let callbackAfterStop = isStopped
    errorStorage = error
    lock.unlock()
    if callbackAfterStop {
      callbackAfterStopExpectation?.fulfill()
    }
    didFinishExpectation?.fulfill()
  }

  func markStopped() {
    lock.lock()
    isStopped = true
    lock.unlock()
  }

  func snapshot() -> (response: URLResponse?, data: Data, chunkSizes: [Int], error: Error?) {
    lock.lock()
    defer { lock.unlock() }
    return (responseStorage, dataStorage, chunkSizesStorage, errorStorage)
  }
}
