import Foundation
import ImageIO

/// A bounded estimate of the decoded memory needed by one image batch item.
///
/// Compressed file size is only a proxy for the decoded bitmap, so the budget
/// deliberately multiplies attachment bytes by a conservative factor. The
/// automatic budget is derived from physical memory but clamped to stable
/// bounds; this prevents a large workstation from turning a batch into an
/// unbounded memory consumer.
public struct ImageBatchMemoryBudget: Equatable, Sendable {
  // ImageIO commonly holds a decoded RGBA surface plus intermediate source
  // and destination buffers. Compressed bytes therefore need a deliberately
  // wide multiplier when pixel dimensions are not persisted in the draft.
  public static let defaultDecodeMultiplier: Int64 = 16
  public static let decodedBytesPerPixel: Int64 = 4
  public static let decodedBufferMultiplier: Int64 = 2
  public static let defaultUnknownAttachmentBytes: Int64 = 1 * 1_024 * 1_024
  public static let minimumTotalBytes: Int64 = 128 * 1_024 * 1_024
  public static let maximumTotalBytes: Int64 = 512 * 1_024 * 1_024

  public let cpuLimit: Int
  public let byteBudget: Int64
  public let decodeMultiplier: Int64
  public let unknownAttachmentBytes: Int64

  public init(
    cpuLimit: Int,
    byteBudget: Int64,
    decodeMultiplier: Int64 = ImageBatchMemoryBudget.defaultDecodeMultiplier,
    unknownAttachmentBytes: Int64 = ImageBatchMemoryBudget.defaultUnknownAttachmentBytes
  ) {
    self.cpuLimit = max(1, cpuLimit)
    self.byteBudget = max(1, byteBudget)
    self.decodeMultiplier = max(1, decodeMultiplier)
    self.unknownAttachmentBytes = max(1, unknownAttachmentBytes)
  }

  /// Builds the production budget from host memory while keeping predictable
  /// lower and upper bounds for tests and for machines with very different
  /// amounts of RAM.
  public init(
    physicalMemory: UInt64,
    activeProcessorCount: Int,
    decodeMultiplier: Int64 = ImageBatchMemoryBudget.defaultDecodeMultiplier,
    unknownAttachmentBytes: Int64 = ImageBatchMemoryBudget.defaultUnknownAttachmentBytes,
    minimumTotalBytes: Int64 = ImageBatchMemoryBudget.minimumTotalBytes,
    maximumTotalBytes: Int64 = ImageBatchMemoryBudget.maximumTotalBytes
  ) {
    let lowerBound = max(1, min(minimumTotalBytes, maximumTotalBytes))
    let upperBound = max(lowerBound, max(minimumTotalBytes, maximumTotalBytes))
    let eighth = physicalMemory / 8
    let memoryFraction = eighth > UInt64(Int64.max) ? Int64.max : Int64(eighth)
    let boundedBytes = min(upperBound, max(lowerBound, memoryFraction))
    self.init(
      cpuLimit: max(1, activeProcessorCount / 2),
      byteBudget: boundedBytes,
      decodeMultiplier: decodeMultiplier,
      unknownAttachmentBytes: unknownAttachmentBytes
    )
  }

  public static func automatic() -> Self {
    Self(
      physicalMemory: ProcessInfo.processInfo.physicalMemory,
      activeProcessorCount: ProcessInfo.processInfo.activeProcessorCount
    )
  }

  /// Returns the estimated decoded-memory cost for the selected image
  /// attachments in one draft. Unknown/legacy byte sizes receive a one-MiB
  /// floor per image so a missing metadata value cannot bypass the budget.
  public func estimatedBytes(
    for draft: ArticleDraft,
    includedAttachmentIDs: Set<UUID>? = nil,
    operation: ImageBatchOperation? = nil
  ) -> Int64 {
    let imageAttachments = draft.attachments.filter { attachment in
      let path = attachment.sourceFilePath ?? attachment.originalFilename
      let fileExtension = URL(fileURLWithPath: path).pathExtension.lowercased()
      let matchesOperation: Bool
      switch operation {
      case .removePrivacyMetadata:
        matchesOperation = attachment.mediaKind == .image
      case .optimizeJPEG:
        matchesOperation = fileExtension == "jpg" || fileExtension == "jpeg"
      case .convertWebP, .resizeLargeImages:
        matchesOperation = attachment.mediaKind == .image
      case .optimizeSVG:
        matchesOperation = fileExtension == "svg"
      case .cropCover16By9:
        matchesOperation = attachment.id == draft.coverAttachmentID
      case nil:
        matchesOperation = attachment.mediaKind == .image
      }
      return matchesOperation
        && (includedAttachmentIDs == nil || includedAttachmentIDs?.contains(attachment.id) == true)
    }
    guard !imageAttachments.isEmpty else { return 1 }

    var decodedPixelBytes: Int64 = 0
    var compressedProxyBytes: Int64 = 0
    for attachment in imageAttachments {
      if let decodedBytes = decodedBytesForKnownPixels(of: attachment) {
        decodedPixelBytes = saturatingAdd(decodedPixelBytes, decodedBytes)
        continue
      }
      compressedProxyBytes = saturatingAdd(
        compressedProxyBytes,
        max(max(0, attachment.byteSize), unknownAttachmentBytes)
      )
    }
    // Pixel dimensions already describe the decoded surface and must not be
    // multiplied by the compressed-size safety factor a second time.
    return saturatingAdd(
      decodedPixelBytes,
      saturatingMultiply(compressedProxyBytes, decodeMultiplier)
    )
  }

  private func pixelDimensions(for attachment: DraftAttachment) -> (width: Int64, height: Int64)? {
    let path = attachment.sourceFilePath ?? attachment.originalFilename
    guard !path.isEmpty,
      let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
      let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
      width.int64Value > 0, height.int64Value > 0
    else { return nil }
    return (width.int64Value, height.int64Value)
  }

  private func decodedBytesForKnownPixels(of attachment: DraftAttachment) -> Int64? {
    guard let dimensions = pixelDimensions(for: attachment),
      dimensions.width <= Int64.max / dimensions.height
    else { return nil }
    let pixelCount = dimensions.width * dimensions.height
    guard pixelCount <= Int64.max / Self.decodedBytesPerPixel else { return nil }
    let surfaceBytes = pixelCount * Self.decodedBytesPerPixel
    guard surfaceBytes <= Int64.max / Self.decodedBufferMultiplier else { return nil }
    return surfaceBytes * Self.decodedBufferMultiplier
  }

  private func saturatingAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
    guard rhs > 0 else { return lhs }
    guard lhs <= Int64.max - rhs else { return Int64.max }
    return lhs + rhs
  }

  private func saturatingMultiply(_ lhs: Int64, _ rhs: Int64) -> Int64 {
    guard lhs > 0, rhs > 0 else { return 0 }
    guard lhs <= Int64.max / rhs else { return Int64.max }
    return lhs * rhs
  }
}

/// Deterministic admission control for image batch tasks. It tracks both CPU
/// slots and estimated decoded bytes; an item larger than the total budget may
/// run only when it is the sole active item.
public struct ImageBatchMemoryScheduler: Equatable, Sendable {
  public struct WorkItem: Equatable, Sendable {
    public let index: Int
    public let estimatedBytes: Int64

    public init(index: Int, estimatedBytes: Int64) {
      self.index = index
      self.estimatedBytes = max(1, estimatedBytes)
    }
  }

  public let cpuLimit: Int
  public let byteBudget: Int64
  public private(set) var runningCount = 0
  public private(set) var runningBytes: Int64 = 0
  public private(set) var peakRunningBytes: Int64 = 0
  public private(set) var isCancelled = false

  private var running: [Int: Int64] = [:]
  private var completed = Set<Int>()

  public init(cpuLimit: Int, byteBudget: Int64) {
    self.cpuLimit = max(1, cpuLimit)
    self.byteBudget = max(1, byteBudget)
  }

  public mutating func cancel() {
    isCancelled = true
  }

  public func canStart(_ item: WorkItem) -> Bool {
    guard !isCancelled,
      running[item.index] == nil,
      !completed.contains(item.index),
      runningCount < cpuLimit
    else { return false }
    if item.estimatedBytes > byteBudget {
      return runningCount == 0
    }
    return runningBytes <= byteBudget - item.estimatedBytes
  }

  @discardableResult
  public mutating func acquire(_ item: WorkItem) -> Bool {
    guard canStart(item) else { return false }
    running[item.index] = item.estimatedBytes
    runningCount += 1
    runningBytes = saturatingAdd(runningBytes, item.estimatedBytes)
    peakRunningBytes = max(peakRunningBytes, runningBytes)
    return true
  }

  @discardableResult
  public mutating func complete(index: Int) -> Bool {
    guard let bytes = running.removeValue(forKey: index) else { return false }
    runningCount -= 1
    runningBytes = max(0, runningBytes - bytes)
    completed.insert(index)
    return true
  }

  /// Finds the first pending item that fits the current admission state. The
  /// scan is deterministic and does not depend on task completion timing.
  public func nextRunnable(in items: [WorkItem]) -> WorkItem? {
    items.first(where: canStart)
  }

  private func saturatingAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
    guard rhs > 0, lhs <= Int64.max - rhs else { return Int64.max }
    return lhs + rhs
  }
}
