import Foundation
import XCTest
@testable import PublishingCoreSupport

final class SafeFileReaderTests: XCTestCase {
  func testReadsRegularFileWithinLimit() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture) }
    try Data("hello".utf8).write(to: fixture.appendingPathComponent("article.md"))

    let value = try SafeFileReader.utf8String(
      relativePath: "article.md",
      under: fixture,
      maximumByteCount: 16
    )

    XCTAssertEqual(value, "hello")
  }

  func testRejectsInvalidByteLimit() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture) }
    let fileURL = fixture.appendingPathComponent("article.md")
    try Data("hello".utf8).write(to: fileURL)

    XCTAssertThrowsError(
      try SafeFileReader.data(at: fileURL, maximumByteCount: 0)
    ) { error in
      guard case SafeFileReadError.invalidByteLimit = error else {
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
      try SafeFileReader.data(at: linkURL, maximumByteCount: 1_024)
    ) { error in
      guard case let SafeFileReadError.cannotOpen(path, _) = error,
            path == linkURL.path else {
        return XCTFail("Unexpected error: \(error)")
      }
    }
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
      try SafeFileReader.utf8String(
        relativePath: "content/article.md",
        under: fixture,
        maximumByteCount: 1_024
      )
    ) { error in
      guard case let SafeFileReadError.cannotOpen(path, _) = error,
            path == "content/article.md" else {
        return XCTFail("Unexpected error: \(error)")
      }
    }
  }

  func testRejectsParentTraversal() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture) }

    XCTAssertThrowsError(
      try SafeFileReader.data(
        relativePath: "../outside.md",
        under: fixture,
        maximumByteCount: 1_024
      )
    ) { error in
      guard case SafeFileReadError.unsafeRelativePath("../outside.md") = error else {
        return XCTFail("Unexpected error: \(error)")
      }
    }
  }

  func testRejectsInvalidUTF8() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture) }
    try Data([0xff, 0xfe, 0xfd]).write(to: fixture.appendingPathComponent("invalid.txt"))

    XCTAssertThrowsError(
      try SafeFileReader.utf8String(
        relativePath: "invalid.txt",
        under: fixture,
        maximumByteCount: 16
      )
    ) { error in
      guard case SafeFileReadError.invalidUTF8("invalid.txt") = error else {
        return XCTFail("Unexpected error: \(error)")
      }
    }
  }

  func testStreamingSHA256MatchesKnownDigest() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture) }
    let fileURL = fixture.appendingPathComponent("digest.txt")
    try Data("hello".utf8).write(to: fileURL)

    let digest = try SafeFileReader.sha256(at: fileURL, maximumByteCount: 16)
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
      try SafeFileReader.sha256(at: fileURL, maximumByteCount: 8)
    ) { error in
      guard case let SafeFileReadError.exceedsByteLimit(path, limit) = error,
            path == fileURL.path,
            limit == 8 else {
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
      try SafeFileReader.sha256(at: linkURL, maximumByteCount: 1_024)
    ) { error in
      guard case let SafeFileReadError.cannotOpen(path, _) = error,
            path == linkURL.path else {
        return XCTFail("Unexpected error: \(error)")
      }
    }
  }

  private func makeFixture() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("safe-file-reader-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}
