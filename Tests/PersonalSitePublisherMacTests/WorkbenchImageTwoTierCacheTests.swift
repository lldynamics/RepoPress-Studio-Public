import AppKit
import Foundation
import XCTest
@testable import PersonalSitePublisherMac

@MainActor
final class WorkbenchImageTwoTierCacheTests: XCTestCase {
  func testStableDiskKeyIsReusedAcrossCacheInstances() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture) }
    let sourceURL = fixture.appendingPathComponent("source.png")
    let cacheURL = fixture.appendingPathComponent("cache", isDirectory: true)
    try writeTestPNG(to: sourceURL, color: .systemRed, width: 12, height: 8)

    let firstCache = WorkbenchImageTwoTierCache(diskCacheDirectory: cacheURL)
    let firstThumbnail = await firstCache.thumbnail(for: sourceURL, maxPixelSize: 64)
    XCTAssertNotNil(firstThumbnail)
    let firstEntries = try cacheEntries(in: cacheURL)
    XCTAssertEqual(firstEntries.count, 1)
    let stableKey = try XCTUnwrap(firstEntries.first)
      .deletingPathExtension()
      .lastPathComponent
    XCTAssertEqual(stableKey.count, 64)
    XCTAssertTrue(stableKey.allSatisfy(\.isHexDigit))

    let secondCache = WorkbenchImageTwoTierCache(diskCacheDirectory: cacheURL)
    let secondThumbnail = await secondCache.thumbnail(for: sourceURL, maxPixelSize: 64)
    XCTAssertNotNil(secondThumbnail)
    XCTAssertEqual(try cacheEntries(in: cacheURL), firstEntries)
  }

  func testSourceMetadataChangeCreatesNewCacheEntry() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture) }
    let sourceURL = fixture.appendingPathComponent("source.png")
    let cacheURL = fixture.appendingPathComponent("cache", isDirectory: true)
    try writeTestPNG(to: sourceURL, color: .systemBlue, width: 10, height: 10)
    let cache = WorkbenchImageTwoTierCache(diskCacheDirectory: cacheURL)
    let firstThumbnail = await cache.thumbnail(for: sourceURL, maxPixelSize: 64)
    XCTAssertNotNil(firstThumbnail)

    try writeTestPNG(to: sourceURL, color: .systemGreen, width: 17, height: 9)
    try FileManager.default.setAttributes(
      [.modificationDate: Date().addingTimeInterval(60)],
      ofItemAtPath: sourceURL.path
    )
    let changedThumbnail = await cache.thumbnail(for: sourceURL, maxPixelSize: 64)
    XCTAssertNotNil(changedThumbnail)

    XCTAssertEqual(try cacheEntries(in: cacheURL).count, 2)
  }

  func testCorruptDiskEntryIsRegeneratedFromSource() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture) }
    let sourceURL = fixture.appendingPathComponent("source.png")
    let cacheURL = fixture.appendingPathComponent("cache", isDirectory: true)
    try writeTestPNG(to: sourceURL, color: .systemOrange, width: 12, height: 12)
    let firstCache = WorkbenchImageTwoTierCache(diskCacheDirectory: cacheURL)
    let firstThumbnail = await firstCache.thumbnail(for: sourceURL, maxPixelSize: 64)
    XCTAssertNotNil(firstThumbnail)
    let cacheEntry = try XCTUnwrap(cacheEntries(in: cacheURL).first)
    try Data("corrupt thumbnail".utf8).write(to: cacheEntry, options: .atomic)

    let secondCache = WorkbenchImageTwoTierCache(diskCacheDirectory: cacheURL)
    let repairedThumbnail = await secondCache.thumbnail(for: sourceURL, maxPixelSize: 64)
    XCTAssertNotNil(repairedThumbnail)

    let repairedData = try Data(contentsOf: cacheEntry)
    XCTAssertNotNil(NSImage(data: repairedData))
  }

  func testInitialMaintenanceRemovesExpiredCacheEntry() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture) }
    let sourceURL = fixture.appendingPathComponent("source.png")
    let cacheURL = fixture.appendingPathComponent("cache", isDirectory: true)
    try FileManager.default.createDirectory(at: cacheURL, withIntermediateDirectories: true)
    try writeTestPNG(to: sourceURL, color: .systemPurple, width: 8, height: 8)
    let expiredURL = cacheURL.appendingPathComponent(
      "\(String(repeating: "a", count: 64)).png"
    )
    try writeTestPNG(to: expiredURL, color: .black, width: 4, height: 4)
    try FileManager.default.setAttributes(
      [.modificationDate: Date().addingTimeInterval(-31 * 24 * 60 * 60)],
      ofItemAtPath: expiredURL.path
    )

    let cache = WorkbenchImageTwoTierCache(diskCacheDirectory: cacheURL)
    let thumbnail = await cache.thumbnail(for: sourceURL, maxPixelSize: 64)
    XCTAssertNotNil(thumbnail)

    XCTAssertFalse(FileManager.default.fileExists(atPath: expiredURL.path))
  }

  func testDifferentPixelSizesUseDifferentCacheEntries() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture) }
    let sourceURL = fixture.appendingPathComponent("source.png")
    let cacheURL = fixture.appendingPathComponent("cache", isDirectory: true)
    try writeTestPNG(to: sourceURL, color: .systemTeal, width: 32, height: 24)
    let cache = WorkbenchImageTwoTierCache(diskCacheDirectory: cacheURL)

    let smallThumbnail = await cache.thumbnail(for: sourceURL, maxPixelSize: 32)
    let largeThumbnail = await cache.thumbnail(for: sourceURL, maxPixelSize: 64)

    XCTAssertNotNil(smallThumbnail)
    XCTAssertNotNil(largeThumbnail)
    XCTAssertEqual(try cacheEntries(in: cacheURL).count, 2)
  }

  func testMaintenanceRejectsOversizedEntryAndSymbolicLink() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture) }
    let cacheURL = fixture.appendingPathComponent("cache", isDirectory: true)
    try FileManager.default.createDirectory(at: cacheURL, withIntermediateDirectories: true)
    let oversizedURL = cacheURL.appendingPathComponent(
      "\(String(repeating: "b", count: 64)).png"
    )
    try Data(repeating: 0x41, count: 129).write(to: oversizedURL)
    let targetURL = fixture.appendingPathComponent("target.png")
    try writeTestPNG(to: targetURL, color: .black, width: 4, height: 4)
    let linkURL = cacheURL.appendingPathComponent(
      "\(String(repeating: "c", count: 64)).png"
    )
    try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: targetURL)
    let cache = WorkbenchImageTwoTierCache(
      diskCacheDirectory: cacheURL,
      policy: testPolicy(maximumDiskEntryByteCount: 128)
    )

    await cache.waitForPendingDiskOperations()

    XCTAssertFalse(FileManager.default.fileExists(atPath: oversizedURL.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: linkURL.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: targetURL.path))
  }

  func testMaintenanceEvictsOldestEntryWhenCountLimitIsExceeded() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture) }
    let cacheURL = fixture.appendingPathComponent("cache", isDirectory: true)
    try FileManager.default.createDirectory(at: cacheURL, withIntermediateDirectories: true)
    let entries = try makeDatedCacheEntries(in: cacheURL)
    let cache = WorkbenchImageTwoTierCache(
      diskCacheDirectory: cacheURL,
      policy: testPolicy(maximumDiskEntryCount: 2)
    )

    await cache.waitForPendingDiskOperations()

    XCTAssertFalse(FileManager.default.fileExists(atPath: entries[0].path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: entries[1].path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: entries[2].path))
  }

  func testMaintenanceEvictsOldestEntryWhenByteLimitIsExceeded() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture) }
    let cacheURL = fixture.appendingPathComponent("cache", isDirectory: true)
    try FileManager.default.createDirectory(at: cacheURL, withIntermediateDirectories: true)
    let entries = try makeDatedCacheEntries(in: cacheURL)
    let newestByteCount = try entries.suffix(2).reduce(0) { partialResult, url in
      let values = try url.resourceValues(forKeys: [.fileSizeKey])
      return partialResult + (values.fileSize ?? 0)
    }
    let cache = WorkbenchImageTwoTierCache(
      diskCacheDirectory: cacheURL,
      policy: testPolicy(
        maximumDiskCacheByteCount: newestByteCount,
        maximumDiskEntryCount: 10
      )
    )

    await cache.waitForPendingDiskOperations()

    XCTAssertFalse(FileManager.default.fileExists(atPath: entries[0].path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: entries[1].path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: entries[2].path))
  }

  func testAwaitedClearRunsAfterQueuedThumbnailGeneration() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture) }
    let sourceURL = fixture.appendingPathComponent("source.png")
    let cacheURL = fixture.appendingPathComponent("cache", isDirectory: true)
    try writeTestPNG(to: sourceURL, color: .systemYellow, width: 32, height: 32)
    let cache = WorkbenchImageTwoTierCache(diskCacheDirectory: cacheURL)
    let generationTask = Task {
      await cache.thumbnail(for: sourceURL, maxPixelSize: 64)
    }
    await Task.yield()

    await cache.clearCache()
    _ = await generationTask.value

    XCTAssertTrue(try cacheEntries(in: cacheURL).isEmpty)
  }

  func testDiskWriteFailureStillReturnsGeneratedThumbnail() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture) }
    let sourceURL = fixture.appendingPathComponent("source.png")
    let cacheURL = fixture.appendingPathComponent("not-a-directory")
    try writeTestPNG(to: sourceURL, color: .systemPink, width: 16, height: 16)
    try Data("occupied".utf8).write(to: cacheURL)
    let cache = WorkbenchImageTwoTierCache(diskCacheDirectory: cacheURL)

    let thumbnail = await cache.thumbnail(for: sourceURL, maxPixelSize: 64)

    XCTAssertNotNil(thumbnail)
    XCTAssertFalse(FileManager.default.fileExists(atPath: cacheURL.appendingPathComponent("entry").path))
  }

  private func cacheEntries(in directoryURL: URL) throws -> [URL] {
    try FileManager.default.contentsOfDirectory(
      at: directoryURL,
      includingPropertiesForKeys: nil
    )
    .filter { $0.pathExtension == "png" }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }
  }

  private func writeTestPNG(
    to url: URL,
    color: NSColor,
    width: Int,
    height: Int
  ) throws {
    let bitmap = try XCTUnwrap(
      NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: width,
        pixelsHigh: height,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
      )
    )
    let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    color.setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()
    NSGraphicsContext.restoreGraphicsState()
    let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    try data.write(to: url, options: .atomic)
  }

  private func makeDatedCacheEntries(in cacheURL: URL) throws -> [URL] {
    let entries = ["d", "e", "f"].map { character in
      cacheURL.appendingPathComponent(
        "\(String(repeating: character, count: 64)).png"
      )
    }
    for (index, entry) in entries.enumerated() {
      try writeTestPNG(
        to: entry,
        color: [.systemRed, .systemGreen, .systemBlue][index],
        width: 8 + index,
        height: 8 + index
      )
      try FileManager.default.setAttributes(
        [.modificationDate: Date().addingTimeInterval(TimeInterval(index - 3))],
        ofItemAtPath: entry.path
      )
    }
    return entries
  }

  private func testPolicy(
    maximumDiskEntryByteCount: Int = 1_024 * 1_024,
    maximumDiskCacheByteCount: Int = 10 * 1_024 * 1_024,
    maximumDiskEntryCount: Int = 100
  ) -> WorkbenchThumbnailCachePolicy {
    WorkbenchThumbnailCachePolicy(
      formatVersion: 2,
      maximumPixelSize: 512,
      maximumDiskEntryByteCount: maximumDiskEntryByteCount,
      maximumDiskCacheByteCount: maximumDiskCacheByteCount,
      maximumDiskEntryCount: maximumDiskEntryCount,
      maximumDiskEntryAge: 30 * 24 * 60 * 60,
      maintenanceInterval: 0,
      maintenanceMarkerName: ".maintenance-tests"
    )
  }

  private func makeFixture() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "workbench-thumbnail-cache-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}
