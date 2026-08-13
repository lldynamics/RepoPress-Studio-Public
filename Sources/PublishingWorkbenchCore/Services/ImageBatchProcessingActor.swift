import Foundation
import os

private let logger = Logger(subsystem: "com.repopress", category: "ImageBatchProcessingActor")

public enum ImageBatchOperation: String, Sendable {
  case optimizeJPEG
  case convertWebP
  case optimizeSVG
  case resizeLargeImages
  case cropCover16By9

  public var progressTitle: String {
    switch self {
    case .optimizeJPEG: CoreL10n.text("压缩 JPEG")
    case .convertWebP: CoreL10n.text("转换 WebP")
    case .optimizeSVG: CoreL10n.text("优化 SVG")
    case .resizeLargeImages: CoreL10n.text("缩放大图")
    case .cropCover16By9: CoreL10n.text("裁剪 16:9 封面")
    }
  }
}

public struct ImageBatchProgress: Equatable, Sendable {
  public let operation: ImageBatchOperation
  public let completedDraftCount: Int
  public let totalDraftCount: Int

  public var fractionCompleted: Double {
    guard totalDraftCount > 0 else { return 0 }
    return Double(completedDraftCount) / Double(totalDraftCount)
  }
}

public struct ImageBatchProcessingResult: Sendable {
  public let updatedDraftsByID: [UUID: ArticleDraft]
  public let optimizedCount: Int
  public let skippedCount: Int
  public let savedBytes: Int64
  public let firstMessage: String?
  public let outputDirectory: URL
}

/// A thread-safe cancellation signal that can be observed while a synchronous
/// image encoder or external `cwebp` process is running.
public final class ImageProcessingCancellationToken: @unchecked Sendable {
  private let lock = NSLock()
  private var cancelled = false

  public init() {}

  public func cancel() {
    lock.lock()
    cancelled = true
    lock.unlock()
  }

  public var isCancelled: Bool {
    lock.lock()
    defer { lock.unlock() }
    return cancelled
  }

  public func throwIfCancelled() throws {
    if isCancelled {
      throw CancellationError()
    }
  }
}

/// Serializes image work away from the main actor. Admission is bounded by
/// both CPU slots and an estimated decoded-memory budget, while cancellation
/// remains deterministic between drafts.
public actor ImageBatchProcessingActor {
  private let service: SiteImageWorkbenchService
  private let memoryBudget: ImageBatchMemoryBudget

  public init(
    service: SiteImageWorkbenchService = SiteImageWorkbenchService(),
    memoryBudget: ImageBatchMemoryBudget = .automatic()
  ) {
    self.service = service
    self.memoryBudget = memoryBudget
  }

  public func process(
    operation: ImageBatchOperation,
    drafts: [ArticleDraft],
    includedAttachmentIDsByDraftID: [UUID: Set<UUID>] = [:],
    destinationRoot: URL,
    cancellationToken: ImageProcessingCancellationToken,
    progress: @MainActor @Sendable @escaping (ImageBatchProgress) -> Void
  ) async throws -> ImageBatchProcessingResult {
    let outputDirectory =
      destinationRoot
      .appendingPathComponent(".image-batch-\(UUID().uuidString)", isDirectory: true)
    var keepOutputDirectory = false
    defer {
      if !keepOutputDirectory {
        do {
          try FileManager.default.removeItem(at: outputDirectory)
        } catch {
          logger.warning(
            "无法删除输出目录 \(outputDirectory.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
          )
        }
      }
    }

    try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    await progress(
      ImageBatchProgress(
        operation: operation, completedDraftCount: 0, totalDraftCount: drafts.count))

    var updatedDraftsByID: [UUID: ArticleDraft] = [:]
    var optimizedCount = 0
    var skippedCount = 0
    var savedBytes: Int64 = 0
    var firstMessageByDraftIndex: [Int: String] = [:]

    // Image encoders are CPU and memory heavy. Admission is bounded by both
    // CPU slots and estimated decoded bytes; an oversized draft runs alone.
    // Each attachment destination is UUID-based, so drafts can safely share
    // the staging directory.
    let service = self.service
    let workItems = drafts.enumerated().map { index, draft in
      ImageBatchMemoryScheduler.WorkItem(
        index: index,
        estimatedBytes: memoryBudget.estimatedBytes(
          for: draft,
          includedAttachmentIDs: includedAttachmentIDsByDraftID[draft.id],
          operation: operation
        )
      )
    }
    var completedDraftCount = 0
    try await withThrowingTaskGroup(
      of: (Int, ImageOptimizationResult).self
    ) { group in
      var scheduler = ImageBatchMemoryScheduler(
        cpuLimit: min(drafts.count, memoryBudget.cpuLimit),
        byteBudget: memoryBudget.byteBudget
      )

      func addRunnableTasks() throws {
        try cancellationToken.throwIfCancelled()
        while let workItem = scheduler.nextRunnable(in: workItems) {
          guard scheduler.acquire(workItem) else { break }
          let draftIndex = workItem.index
          let draft = drafts[draftIndex]
          let includedAttachmentIDs = includedAttachmentIDsByDraftID[draft.id]
          group.addTask {
            try Task.checkCancellation()
            try cancellationToken.throwIfCancelled()
            let result = try Self.process(
              service: service,
              operation: operation,
              draft: draft,
              includedAttachmentIDs: includedAttachmentIDs,
              destinationDirectory: outputDirectory,
              cancellationToken: cancellationToken
            )
            try Task.checkCancellation()
            try cancellationToken.throwIfCancelled()
            return (draftIndex, result)
          }
        }
      }

      try addRunnableTasks()

      while let (draftIndex, result) = try await group.next() {
        _ = scheduler.complete(index: draftIndex)
        try cancellationToken.throwIfCancelled()
        let draft = drafts[draftIndex]
        if result.optimizedCount > 0 {
          updatedDraftsByID[draft.id] = result.draft
        }
        optimizedCount += result.optimizedCount
        skippedCount += result.skippedCount
        savedBytes += result.savedBytes
        if let message = result.messages.first {
          firstMessageByDraftIndex[draftIndex] = message
        }
        completedDraftCount += 1
        await progress(
          ImageBatchProgress(
            operation: operation,
            completedDraftCount: completedDraftCount,
            totalDraftCount: drafts.count
          ))
        try addRunnableTasks()
      }
    }

    try cancellationToken.throwIfCancelled()
    keepOutputDirectory = true
    let firstMessage = drafts.indices.lazy.compactMap { firstMessageByDraftIndex[$0] }.first
    return ImageBatchProcessingResult(
      updatedDraftsByID: updatedDraftsByID,
      optimizedCount: optimizedCount,
      skippedCount: skippedCount,
      savedBytes: savedBytes,
      firstMessage: firstMessage,
      outputDirectory: outputDirectory
    )
  }

  private nonisolated static func process(
    service: SiteImageWorkbenchService,
    operation: ImageBatchOperation,
    draft: ArticleDraft,
    includedAttachmentIDs: Set<UUID>?,
    destinationDirectory: URL,
    cancellationToken: ImageProcessingCancellationToken
  ) throws -> ImageOptimizationResult {
    switch operation {
    case .optimizeJPEG:
      return try service.optimizeJPEGAttachments(
        draft: draft,
        destinationDirectory: destinationDirectory,
        cancellationToken: cancellationToken,
        includedAttachmentIDs: includedAttachmentIDs
      )
    case .convertWebP:
      return try service.convertAttachmentsToWebP(
        draft: draft,
        destinationDirectory: destinationDirectory,
        cancellationToken: cancellationToken,
        includedAttachmentIDs: includedAttachmentIDs
      )
    case .optimizeSVG:
      return try service.optimizeSVGAttachments(
        draft: draft,
        destinationDirectory: destinationDirectory,
        cancellationToken: cancellationToken,
        includedAttachmentIDs: includedAttachmentIDs
      )
    case .resizeLargeImages:
      return try service.resizeLargeAttachments(
        draft: draft,
        destinationDirectory: destinationDirectory,
        cancellationToken: cancellationToken,
        includedAttachmentIDs: includedAttachmentIDs
      )
    case .cropCover16By9:
      guard let coverAttachmentID = draft.coverAttachmentID else {
        return ImageOptimizationResult(
          draft: draft,
          optimizedCount: 0,
          skippedCount: 1,
          savedBytes: 0,
          messages: ["请先设置封面图，再裁剪 16:9 封面。"]
        )
      }
      return try service.cropAttachmentToAspectRatio(
        draft: draft,
        attachmentID: coverAttachmentID,
        destinationDirectory: destinationDirectory,
        aspectWidth: 16,
        aspectHeight: 9
      )
    }
  }
}
