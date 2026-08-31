import Darwin
import Dispatch
import Foundation

/// Relays newline-delimited MCP frames through a bounded buffer before the
/// official SDK transport sees them. Both descriptors are non-blocking so
/// downstream backpressure can never trap lifecycle operations in a write.
final class PublishingMCPFrameRelay: @unchecked Sendable {
  private static let readChunkByteCount = 64 * 1_024
  private static let maximumFramesPerQueueTurn = 256

  private let input: FileHandle
  private let output: FileHandle
  private let maximumFrameByteCount: Int
  private let queue = DispatchQueue(
    label: "com.repopress.publishing-mcp-frame-relay",
    qos: .utility
  )
  private let queueKey = DispatchSpecificKey<UInt8>()

  private var readSource: DispatchSourceRead?
  private var writeSource: DispatchSourceWrite?
  private var isReadSourceSuspended = false
  private var isBufferedInputProcessingScheduled = false
  private var pendingInput = Data()
  private var pendingOutput: Data?
  private var pendingOutputOffset = 0
  private var isStopped = false
  private var exceededFrameLimit = false

  init(
    input: FileHandle,
    output: FileHandle,
    maximumFrameByteCount: Int
  ) {
    self.input = input
    self.output = output
    self.maximumFrameByteCount = maximumFrameByteCount
    queue.setSpecific(key: queueKey, value: 1)
  }

  deinit {
    stop()
  }

  func start() {
    synchronized {
      guard !isStopped, readSource == nil else { return }
      guard setNonBlocking(input.fileDescriptor), setNonBlocking(output.fileDescriptor) else {
        stopOnQueue()
        return
      }

      let source = DispatchSource.makeReadSource(
        fileDescriptor: input.fileDescriptor,
        queue: queue
      )
      source.setEventHandler { [weak self] in
        self?.consumeReadableData()
      }
      readSource = source
      source.resume()
    }
  }

  /// Idempotently stops the relay. Work performed on the serial queue uses
  /// only non-blocking syscalls, so callers never wait for pipe capacity.
  func stop() {
    synchronized {
      stopOnQueue()
    }
  }

  var didExceedFrameLimit: Bool {
    synchronized { exceededFrameLimit }
  }

  private func consumeReadableData() {
    guard !isStopped, pendingOutput == nil else { return }

    if forwardBufferedFrames() {
      scheduleBufferedInputProcessing()
      return
    }
    guard !isStopped, pendingOutput == nil else { return }

    var buffer = [UInt8](repeating: 0, count: Self.readChunkByteCount)
    let bytesRead = buffer.withUnsafeMutableBytes { rawBuffer in
      Darwin.read(input.fileDescriptor, rawBuffer.baseAddress, rawBuffer.count)
    }
    if bytesRead > 0 {
      pendingInput.append(contentsOf: buffer.prefix(bytesRead))
      if forwardBufferedFrames() {
        scheduleBufferedInputProcessing()
      }
      return
    }
    if bytesRead == 0 {
      stopOnQueue()
      return
    }
    if errno == EINTR {
      scheduleBufferedInputProcessing()
    } else if errno != EAGAIN, errno != EWOULDBLOCK {
      stopOnQueue()
    }
  }

  /// Returns true when complete buffered frames remain after this bounded
  /// queue turn. Only one frame/remainder is ever pending on the output side.
  private func forwardBufferedFrames() -> Bool {
    var forwardedFrameCount = 0
    while pendingOutput == nil,
      let newlineIndex = pendingInput.firstIndex(of: UInt8(ascii: "\n"))
    {
      let frameByteCount = pendingInput.distance(
        from: pendingInput.startIndex,
        to: newlineIndex
      )
      guard frameByteCount <= maximumFrameByteCount else {
        failForFrameLimit()
        return false
      }

      let upperBound = pendingInput.index(after: newlineIndex)
      pendingOutput = Data(pendingInput[pendingInput.startIndex..<upperBound])
      pendingOutputOffset = 0
      pendingInput.removeSubrange(pendingInput.startIndex..<upperBound)
      drainPendingOutput()
      guard !isStopped else { return false }

      forwardedFrameCount += 1
      if forwardedFrameCount >= Self.maximumFramesPerQueueTurn {
        return pendingOutput == nil
          && pendingInput.firstIndex(of: UInt8(ascii: "\n")) != nil
      }
    }

    if pendingOutput == nil,
      pendingInput.firstIndex(of: UInt8(ascii: "\n")) == nil,
      pendingInput.count > maximumFrameByteCount
    {
      failForFrameLimit()
    }
    return false
  }

  private func drainPendingOutput() {
    while let data = pendingOutput, pendingOutputOffset < data.count {
      let bytesWritten = data.withUnsafeBytes { rawBuffer in
        Darwin.write(
          output.fileDescriptor,
          rawBuffer.baseAddress?.advanced(by: pendingOutputOffset),
          rawBuffer.count - pendingOutputOffset
        )
      }
      if bytesWritten > 0 {
        pendingOutputOffset += bytesWritten
        continue
      }
      if bytesWritten == -1, errno == EINTR {
        continue
      }
      if bytesWritten == -1, errno == EAGAIN || errno == EWOULDBLOCK {
        pauseReadingForBackpressure()
        installWriteSourceIfNeeded()
        return
      }
      stopOnQueue()
      return
    }

    pendingOutput = nil
    pendingOutputOffset = 0
  }

  private func handleWritableOutput() {
    guard !isStopped else { return }
    drainPendingOutput()
    guard !isStopped, pendingOutput == nil else { return }

    let completedSource = writeSource
    writeSource = nil
    completedSource?.cancel()

    if forwardBufferedFrames() {
      scheduleBufferedInputProcessing()
    }
    if !isStopped, pendingOutput == nil {
      resumeReadingAfterBackpressure()
    }
  }

  private func pauseReadingForBackpressure() {
    guard let readSource, !isReadSourceSuspended else { return }
    readSource.suspend()
    isReadSourceSuspended = true
  }

  private func resumeReadingAfterBackpressure() {
    guard let readSource, isReadSourceSuspended else { return }
    isReadSourceSuspended = false
    readSource.resume()
  }

  private func installWriteSourceIfNeeded() {
    guard writeSource == nil, !isStopped else { return }
    let source = DispatchSource.makeWriteSource(
      fileDescriptor: output.fileDescriptor,
      queue: queue
    )
    source.setEventHandler { [weak self] in
      self?.handleWritableOutput()
    }
    writeSource = source
    source.resume()
  }

  private func scheduleBufferedInputProcessing() {
    guard !isBufferedInputProcessingScheduled, !isStopped else { return }
    isBufferedInputProcessingScheduled = true
    queue.async { [weak self] in
      guard let self else { return }
      self.isBufferedInputProcessingScheduled = false
      self.consumeReadableData()
    }
  }

  private func failForFrameLimit() {
    exceededFrameLimit = true
    stopOnQueue()
  }

  private func stopOnQueue() {
    guard !isStopped else { return }
    isStopped = true
    isBufferedInputProcessingScheduled = false

    if isReadSourceSuspended {
      isReadSourceSuspended = false
      readSource?.resume()
    }
    readSource?.cancel()
    writeSource?.cancel()
    readSource = nil
    writeSource = nil

    pendingInput.removeAll(keepingCapacity: false)
    pendingOutput = nil
    pendingOutputOffset = 0
    input.closeFile()
    output.closeFile()
  }

  private func setNonBlocking(_ fileDescriptor: Int32) -> Bool {
    let flags = Darwin.fcntl(fileDescriptor, F_GETFL)
    guard flags >= 0 else { return false }
    return Darwin.fcntl(fileDescriptor, F_SETFL, flags | O_NONBLOCK) >= 0
  }

  private func synchronized<T>(_ operation: () -> T) -> T {
    if DispatchQueue.getSpecific(key: queueKey) != nil {
      return operation()
    }
    return queue.sync(execute: operation)
  }
}
