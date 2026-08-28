import Foundation

/// Relays newline-delimited MCP frames through a bounded buffer before the
/// official SDK transport sees them. Foundation pipes keep each read bounded;
/// this class additionally prevents a server from growing an unterminated JSON
/// line without limit inside `StdioTransport`.
final class PublishingMCPFrameRelay: @unchecked Sendable {
  private let input: FileHandle
  private let output: FileHandle
  private let maximumFrameByteCount: Int
  private let lock = NSLock()
  private var pendingData = Data()
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
  }

  func start() {
    lock.lock()
    defer { lock.unlock() }
    guard !isStopped else { return }
    input.readabilityHandler = { [weak self] _ in
      self?.consumeReadableData()
    }
  }

  func stop() {
    lock.lock()
    defer { lock.unlock() }
    stopLocked()
  }

  var didExceedFrameLimit: Bool {
    lock.lock()
    defer { lock.unlock() }
    return exceededFrameLimit
  }

  private func consumeReadableData() {
    lock.lock()
    defer { lock.unlock() }
    guard !isStopped else { return }

    let data = input.availableData
    guard !data.isEmpty else {
      stopLocked()
      return
    }
    pendingData.append(data)

    while let newlineIndex = pendingData.firstIndex(of: UInt8(ascii: "\n")) {
      let frameByteCount = pendingData.distance(
        from: pendingData.startIndex,
        to: newlineIndex
      )
      guard frameByteCount <= maximumFrameByteCount else {
        exceededFrameLimit = true
        stopLocked()
        return
      }

      let frameRange = pendingData.startIndex...newlineIndex
      let frame = Data(pendingData[frameRange])
      pendingData.removeSubrange(frameRange)
      do {
        try output.write(contentsOf: frame)
      } catch {
        stopLocked()
        return
      }
    }

    guard pendingData.count <= maximumFrameByteCount else {
      exceededFrameLimit = true
      stopLocked()
      return
    }
  }

  private func stopLocked() {
    guard !isStopped else { return }
    isStopped = true
    input.readabilityHandler = nil
    pendingData.removeAll(keepingCapacity: false)
    try? input.close()
    try? output.close()
  }
}
