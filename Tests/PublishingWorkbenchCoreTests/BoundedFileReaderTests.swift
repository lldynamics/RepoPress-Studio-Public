import Foundation
import XCTest
@testable import PublishingWorkbenchCore

final class BoundedFileReaderTests: XCTestCase {
  func testReadsRegularFileWithinLimit() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture) }
    let fileURL = fixture.appendingPathComponent("article.md")
    try Data("hello".utf8).write(to: fileURL)

    let value = try BoundedFileReader.utf8String(
      relativePath: "article.md",
      under: fixture,
      maximumByteCount: 16
    )

    XCTAssertEqual(value, "hello")
  }

  func testRejectsFileThatExceedsLimit() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture) }
    let fileURL = fixture.appendingPathComponent("large.md")
    try Data(repeating: 0x41, count: 32).write(to: fileURL)

    XCTAssertThrowsError(
      try BoundedFileReader.data(at: fileURL, maximumByteCount: 8)
    ) { error in
      guard case BoundedFileReadError.exceedsByteLimit = error else {
        return XCTFail("Unexpected error: \(error)")
      }
    }
  }

  func testRejectsFinalSymbolicLink() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture) }
    let targetURL = fixture.appendingPathComponent("target.md")
    let linkURL = fixture.appendingPathComponent("link.md")
    try Data("private".utf8).write(to: targetURL)
    try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: targetURL)

    XCTAssertThrowsError(
      try BoundedFileReader.data(at: linkURL, maximumByteCount: 1_024)
    )
  }

  func testAnchoredReadRejectsSymbolicLinkDirectory() throws {
    let fixture = try makeFixture()
    let outside = try makeFixture()
    defer {
      try? FileManager.default.removeItem(at: fixture)
      try? FileManager.default.removeItem(at: outside)
    }
    try Data("outside".utf8).write(to: outside.appendingPathComponent("article.md"))
    try FileManager.default.createSymbolicLink(
      at: fixture.appendingPathComponent("content"),
      withDestinationURL: outside
    )

    XCTAssertThrowsError(
      try BoundedFileReader.utf8String(
        relativePath: "content/article.md",
        under: fixture,
        maximumByteCount: 1_024
      )
    )
  }

  func testRejectsParentTraversal() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture) }

    XCTAssertThrowsError(
      try BoundedFileReader.data(
        relativePath: "../outside.md",
        under: fixture,
        maximumByteCount: 1_024
      )
    ) { error in
      guard case BoundedFileReadError.unsafeRelativePath = error else {
        return XCTFail("Unexpected error: \(error)")
      }
    }
  }

  func testStreamingSHA256MatchesKnownDigest() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture) }
    let fileURL = fixture.appendingPathComponent("digest.txt")
    try Data("hello".utf8).write(to: fileURL)

    let digest = try BoundedFileReader.sha256(
      at: fileURL,
      maximumByteCount: 16
    )
    let digestText = digest.map { String(format: "%02x", $0) }.joined()

    XCTAssertEqual(
      digestText,
      "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
    )
  }

  func testStreamingSHA256RejectsOversizedFile() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture) }
    let fileURL = fixture.appendingPathComponent("large-digest.bin")
    try Data(repeating: 0x41, count: 32).write(to: fileURL)

    XCTAssertThrowsError(
      try BoundedFileReader.sha256(at: fileURL, maximumByteCount: 8)
    ) { error in
      guard case BoundedFileReadError.exceedsByteLimit = error else {
        return XCTFail("Unexpected error: \(error)")
      }
    }
  }

  func testStreamingSHA256RejectsSymbolicLink() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture) }
    let targetURL = fixture.appendingPathComponent("target.bin")
    let linkURL = fixture.appendingPathComponent("digest-link.bin")
    try Data("private".utf8).write(to: targetURL)
    try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: targetURL)

    XCTAssertThrowsError(
      try BoundedFileReader.sha256(at: linkURL, maximumByteCount: 1_024)
    )
  }

  private func makeFixture() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("bounded-file-reader-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}
