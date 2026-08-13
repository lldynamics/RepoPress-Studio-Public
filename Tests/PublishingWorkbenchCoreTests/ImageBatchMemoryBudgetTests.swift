import XCTest

@testable import PublishingWorkbenchCore

final class ImageBatchMemoryBudgetTests: XCTestCase {
  func testAutomaticBudgetHasStableBoundsAndCPULimit() {
    let tinyMachine = ImageBatchMemoryBudget(
      physicalMemory: 1,
      activeProcessorCount: 0
    )
    XCTAssertEqual(tinyMachine.byteBudget, ImageBatchMemoryBudget.minimumTotalBytes)
    XCTAssertEqual(tinyMachine.cpuLimit, 1)

    let largeMachine = ImageBatchMemoryBudget(
      physicalMemory: UInt64.max,
      activeProcessorCount: 16
    )
    XCTAssertEqual(largeMachine.byteBudget, ImageBatchMemoryBudget.maximumTotalBytes)
    XCTAssertEqual(largeMachine.cpuLimit, 8)
  }

  func testEstimatedDraftBytesUsesImageAttachmentsAndDecodeMultiplier() {
    let image = DraftAttachment(
      originalFilename: "hero.jpg",
      relativePublishPath: "/images/hero.jpg",
      repositoryPath: "static/images/hero.jpg",
      byteSize: 10
    )
    let video = DraftAttachment(
      originalFilename: "movie.mp4",
      relativePublishPath: "/media/movie.mp4",
      repositoryPath: "static/media/movie.mp4",
      byteSize: 10_000
    )
    let draft = ArticleDraft(
      siteProfileID: SiteProfile.defaultProfile.id,
      title: "Budget",
      slug: "budget",
      attachments: [image, video]
    )
    let budget = ImageBatchMemoryBudget(
      cpuLimit: 2,
      byteBudget: 100,
      decodeMultiplier: 4,
      unknownAttachmentBytes: 2
    )

    XCTAssertEqual(budget.estimatedBytes(for: draft), 40)
    XCTAssertEqual(
      budget.estimatedBytes(for: draft, includedAttachmentIDs: [video.id]),
      1
    )
    XCTAssertEqual(
      budget.estimatedBytes(for: draft, operation: .optimizeSVG),
      1
    )
  }

  func testSmallItemsCanRunInParallelWithoutExceedingByteBudget() {
    var scheduler = ImageBatchMemoryScheduler(cpuLimit: 3, byteBudget: 100)
    let items = [
      ImageBatchMemoryScheduler.WorkItem(index: 0, estimatedBytes: 40),
      ImageBatchMemoryScheduler.WorkItem(index: 1, estimatedBytes: 40),
      ImageBatchMemoryScheduler.WorkItem(index: 2, estimatedBytes: 40),
    ]

    XCTAssertTrue(scheduler.acquire(items[0]))
    XCTAssertTrue(scheduler.acquire(items[1]))
    XCTAssertFalse(scheduler.acquire(items[2]))
    XCTAssertEqual(scheduler.runningBytes, 80)
    XCTAssertLessThanOrEqual(scheduler.peakRunningBytes, 100)

    XCTAssertTrue(scheduler.complete(index: 0))
    XCTAssertTrue(scheduler.acquire(items[2]))
    XCTAssertLessThanOrEqual(scheduler.peakRunningBytes, 100)
  }

  func testOversizedItemRunsAloneAndCancellationPreventsRefill() {
    var scheduler = ImageBatchMemoryScheduler(cpuLimit: 4, byteBudget: 100)
    let oversized = ImageBatchMemoryScheduler.WorkItem(index: 0, estimatedBytes: 250)
    let small = ImageBatchMemoryScheduler.WorkItem(index: 1, estimatedBytes: 20)

    XCTAssertTrue(scheduler.acquire(oversized))
    XCTAssertTrue(scheduler.runningBytes > scheduler.byteBudget)
    XCTAssertFalse(scheduler.acquire(small))
    XCTAssertTrue(scheduler.complete(index: oversized.index))
    XCTAssertTrue(scheduler.acquire(small))
    scheduler.cancel()
    XCTAssertFalse(
      scheduler.acquire(
        ImageBatchMemoryScheduler.WorkItem(index: 2, estimatedBytes: 20)
      ))
    XCTAssertNil(
      scheduler.nextRunnable(in: [
        ImageBatchMemoryScheduler.WorkItem(index: 3, estimatedBytes: 20)
      ]))
  }
}
