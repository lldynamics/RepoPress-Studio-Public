import AppKit
import Foundation
import PublishingWorkbenchCore
import SwiftUI
import UniformTypeIdentifiers
import WebKit
#if canImport(Darwin)
import Darwin
#endif
struct MarkdownPreviewAssetResource: Hashable, Sendable {
  let attachmentID: UUID
  let sourceURL: URL
  let mimeType: String
  let previewURLString: String

  static func resources(for attachments: [DraftAttachment]) -> [Self] {
    var seenAttachmentIDs: Set<UUID> = []
    return attachments.compactMap { attachment in
      guard seenAttachmentIDs.insert(attachment.id).inserted,
            let sourceFilePath = attachment.sourceFilePath?.nilIfEmpty else {
        return nil
      }
      let sourceURL = URL(fileURLWithPath: sourceFilePath)
        .standardizedFileURL
        .resolvingSymlinksInPath()
      guard FileManager.default.isReadableFile(atPath: sourceURL.path),
            let values = try? sourceURL.resourceValues(forKeys: [
              .isRegularFileKey,
              .contentModificationDateKey,
              .fileSizeKey,
            ]),
            values.isRegularFile == true else {
        return nil
      }

      let expectedByteCount = values.fileSize ?? Int(attachment.byteSize)
      let modificationTime = Int64(
        (values.contentModificationDate?.timeIntervalSince1970 ?? 0) * 1_000
      )
      let revision = "\(modificationTime)-\(expectedByteCount)"
      let identifier = attachment.id.uuidString.lowercased()
      let previewURL = "\(MarkdownPreviewAssetService.URLScheme)://attachment/\(identifier)?v=\(revision)"
      let pathExtension = sourceURL.pathExtension.nilIfEmpty
        ?? URL(fileURLWithPath: attachment.originalFilename).pathExtension
      let mimeType = UTType(filenameExtension: pathExtension)?.preferredMIMEType
        ?? (attachment.mediaKind == .video
          ? VideoFileSupport.mimeType(for: sourceURL.path)
          : "application/octet-stream")
      return Self(
        attachmentID: attachment.id,
        sourceURL: sourceURL,
        mimeType: mimeType,
        previewURLString: previewURL
      )
    }
  }
}
struct MarkdownPreviewAssetByteRange: Equatable, Sendable {
  let lowerBound: Int64
  let upperBound: Int64

  var count: Int64 { upperBound - lowerBound + 1 }

  static func resolve(header: String?, fileSize: Int64) throws -> Self? {
    guard let header = header?.trimmingCharacters(in: .whitespacesAndNewlines),
          !header.isEmpty else {
      return nil
    }
    guard fileSize > 0,
          header.lowercased().hasPrefix("bytes="),
          !header.contains(",") else {
      throw MarkdownPreviewAssetRangeError.unsatisfiable
    }

    let value = String(header.dropFirst("bytes=".count))
    let bounds = value.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
    guard bounds.count == 2 else {
      throw MarkdownPreviewAssetRangeError.unsatisfiable
    }

    if bounds[0].isEmpty {
      guard let suffixCount = Int64(bounds[1]), suffixCount > 0 else {
        throw MarkdownPreviewAssetRangeError.unsatisfiable
      }
      let count = min(suffixCount, fileSize)
      return Self(lowerBound: fileSize - count, upperBound: fileSize - 1)
    }

    guard let lowerBound = Int64(bounds[0]),
          lowerBound >= 0,
          lowerBound < fileSize else {
      throw MarkdownPreviewAssetRangeError.unsatisfiable
    }
    let upperBound: Int64
    if bounds[1].isEmpty {
      upperBound = fileSize - 1
    } else {
      guard let requestedUpperBound = Int64(bounds[1]),
            requestedUpperBound >= lowerBound else {
        throw MarkdownPreviewAssetRangeError.unsatisfiable
      }
      upperBound = min(requestedUpperBound, fileSize - 1)
    }
    return Self(lowerBound: lowerBound, upperBound: upperBound)
  }
}

private enum MarkdownPreviewAssetRangeError: Error {
  case unsatisfiable
}

@MainActor
private final class MarkdownPreviewAssetTaskSink {
  private let urlSchemeTask: WKURLSchemeTask
  private let onCompletion: @MainActor () -> Void
  private var isActive = true

  init(
    urlSchemeTask: WKURLSchemeTask,
    onCompletion: @escaping @MainActor () -> Void
  ) {
    self.urlSchemeTask = urlSchemeTask
    self.onCompletion = onCompletion
  }

  func sendResponse(
    url: URL,
    statusCode: Int,
    headers: [String: String]
  ) -> Bool {
    guard isActive else { return false }
    guard let response = HTTPURLResponse(
      url: url,
      statusCode: statusCode,
      httpVersion: "HTTP/1.1",
      headerFields: headers
    ) else {
      fail(.badServerResponse)
      return false
    }
    urlSchemeTask.didReceive(response)
    return true
  }

  func sendData(_ data: Data) -> Bool {
    guard isActive else { return false }
    urlSchemeTask.didReceive(data)
    return true
  }

  func finish() {
    guard isActive else { return }
    isActive = false
    urlSchemeTask.didFinish()
    onCompletion()
  }

  func fail(_ code: URLError.Code) {
    guard isActive else { return }
    isActive = false
    urlSchemeTask.didFailWithError(URLError(code))
    onCompletion()
  }

  func cancel() {
    isActive = false
  }
}

@MainActor
private final class MarkdownPreviewAssetLoadOperation {
  let id: UUID
  let sink: MarkdownPreviewAssetTaskSink
  var worker: Task<Void, Never>?

  init(id: UUID, sink: MarkdownPreviewAssetTaskSink) {
    self.id = id
    self.sink = sink
  }

  func cancel() {
    worker?.cancel()
    sink.cancel()
  }
}

private enum MarkdownPreviewAssetFileStreamer {
  static func stream(
    resource: MarkdownPreviewAssetResource,
    rangeHeader: String?,
    requestURL: URL,
    maximumByteCount: Int,
    chunkByteCount: Int,
    sink: MarkdownPreviewAssetTaskSink
  ) async {
#if canImport(Darwin)
    guard !Task.isCancelled else { return }
    let descriptor = resource.sourceURL.path.withCString {
      Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
    }
    guard descriptor >= 0 else {
      let code: URLError.Code = errno == ENOENT ? .fileDoesNotExist : .noPermissionsToReadFile
      await sink.fail(code)
      return
    }
    defer { Darwin.close(descriptor) }

    var metadata = stat()
    guard Darwin.fstat(descriptor, &metadata) == 0,
          (metadata.st_mode & S_IFMT) == S_IFREG,
          metadata.st_size >= 0,
          metadata.st_size <= off_t(maximumByteCount) else {
      await sink.fail(.dataLengthExceedsMaximum)
      return
    }

    let fileSize = Int64(metadata.st_size)
    let requestedRange: MarkdownPreviewAssetByteRange?
    do {
      requestedRange = try MarkdownPreviewAssetByteRange.resolve(
        header: rangeHeader,
        fileSize: fileSize
      )
    } catch {
      guard await sink.sendResponse(
        url: requestURL,
        statusCode: 416,
        headers: [
          "Accept-Ranges": "bytes",
          "Content-Range": "bytes */\(fileSize)",
          "Content-Length": "0",
        ]
      ) else {
        return
      }
      await sink.finish()
      return
    }

    let transferRange = requestedRange
      ?? (fileSize > 0
        ? MarkdownPreviewAssetByteRange(lowerBound: 0, upperBound: fileSize - 1)
        : nil)
    guard await sink.sendResponse(
      url: requestURL,
      statusCode: requestedRange == nil ? 200 : 206,
      headers: responseHeaders(
        mimeType: resource.mimeType,
        fileSize: fileSize,
        range: requestedRange
      )
    ) else {
      return
    }

    if let transferRange {
      var offset = transferRange.lowerBound
      var remainingByteCount = transferRange.count
      var buffer = [UInt8](repeating: 0, count: chunkByteCount)
      while remainingByteCount > 0 {
        guard !Task.isCancelled else { return }
        let requestedByteCount = min(Int64(buffer.count), remainingByteCount)
        let bytesRead = buffer.withUnsafeMutableBytes { rawBuffer in
          Darwin.pread(
            descriptor,
            rawBuffer.baseAddress,
            Int(requestedByteCount),
            off_t(offset)
          )
        }
        if bytesRead < 0 {
          if errno == EINTR { continue }
          await sink.fail(.cannotDecodeRawData)
          return
        }
        guard bytesRead > 0 else {
          await sink.fail(.cannotDecodeRawData)
          return
        }
        guard await sink.sendData(Data(buffer.prefix(bytesRead))) else {
          return
        }
        offset += Int64(bytesRead)
        remainingByteCount -= Int64(bytesRead)
      }
    }

    await sink.finish()
#else
    await sink.fail(.unsupportedURL)
#endif
  }

  private static func responseHeaders(
    mimeType: String,
    fileSize: Int64,
    range: MarkdownPreviewAssetByteRange?
  ) -> [String: String] {
    var headers = [
      "Accept-Ranges": "bytes",
      "Cache-Control": "no-store",
      "Content-Length": String(range?.count ?? fileSize),
      "Content-Type": mimeType,
    ]
    if let range {
      headers["Content-Range"] = "bytes \(range.lowerBound)-\(range.upperBound)/\(fileSize)"
    }
    return headers
  }
}

@MainActor
final class MarkdownPreviewAssetSchemeHandler: NSObject, WKURLSchemeHandler {
  private static let maximumImageByteCount = 64 * 1024 * 1024
  private static let maximumVideoByteCount = 256 * 1024 * 1024
  private static let streamChunkByteCount = 64 * 1024

  private var resourceByAttachmentID: [String: MarkdownPreviewAssetResource] = [:]
  private var loadOperationByTaskID: [ObjectIdentifier: MarkdownPreviewAssetLoadOperation] = [:]

  func update(resources: [MarkdownPreviewAssetResource]) {
    resourceByAttachmentID = Dictionary(
      uniqueKeysWithValues: resources.map {
        ($0.attachmentID.uuidString.lowercased(), $0)
      }
    )
  }

  func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
    guard let requestURL = urlSchemeTask.request.url,
          requestURL.scheme == MarkdownPreviewAssetService.URLScheme,
          requestURL.host == "attachment",
          let identifier = requestURL.pathComponents.dropFirst().first,
          let resource = resource(for: identifier.lowercased()) else {
      urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
      return
    }

    let taskID = ObjectIdentifier(urlSchemeTask)
    loadOperationByTaskID.removeValue(forKey: taskID)?.cancel()
    let operationID = UUID()
    let sink = MarkdownPreviewAssetTaskSink(
      urlSchemeTask: urlSchemeTask
    ) { [weak self] in
      self?.finishLoad(taskID: taskID, operationID: operationID)
    }
    let operation = MarkdownPreviewAssetLoadOperation(id: operationID, sink: sink)
    loadOperationByTaskID[taskID] = operation
    let rangeHeader = urlSchemeTask.request.value(forHTTPHeaderField: "Range")
    let maximumByteCount = resource.mimeType.hasPrefix("video/")
      ? Self.maximumVideoByteCount
      : Self.maximumImageByteCount
    operation.worker = Task.detached(priority: .utility) {
      await MarkdownPreviewAssetFileStreamer.stream(
        resource: resource,
        rangeHeader: rangeHeader,
        requestURL: requestURL,
        maximumByteCount: maximumByteCount,
        chunkByteCount: Self.streamChunkByteCount,
        sink: sink
      )
    }
  }

  func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
    let taskID = ObjectIdentifier(urlSchemeTask)
    loadOperationByTaskID.removeValue(forKey: taskID)?.cancel()
  }

  private func resource(for attachmentID: String) -> MarkdownPreviewAssetResource? {
    resourceByAttachmentID[attachmentID]
  }

  private func finishLoad(taskID: ObjectIdentifier, operationID: UUID) {
    guard loadOperationByTaskID[taskID]?.id == operationID else { return }
    loadOperationByTaskID.removeValue(forKey: taskID)
  }
}
