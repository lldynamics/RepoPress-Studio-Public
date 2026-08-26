import Foundation
import XCTest
@testable import PublishingWorkbenchCore

final class BoundedFileReaderTests: XCTestCase {
  func testFacadeReadsRegularFileWithinLimit() throws {
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

  func testFacadeTranslatesUnsafeRelativePath() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture) }

    XCTAssertThrowsError(
      try BoundedFileReader.data(
        relativePath: "../outside.md",
        under: fixture,
        maximumByteCount: 1_024
      )
    ) { error in
      guard case BoundedFileReadError.unsafeRelativePath("../outside.md") = error else {
        return XCTFail("Unexpected error: \(error)")
      }
      XCTAssertFalse((error as? LocalizedError)?.errorDescription?.isEmpty ?? true)
    }
  }

  func testFacadeTranslatesByteLimitAndLocalizesError() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture) }
    let fileURL = fixture.appendingPathComponent("large.md")
    try Data(repeating: 0x41, count: 32).write(to: fileURL)

    XCTAssertThrowsError(
      try BoundedFileReader.data(at: fileURL, maximumByteCount: 8)
    ) { error in
      guard case let BoundedFileReadError.exceedsByteLimit(path, limit) = error,
            path == fileURL.path,
            limit == 8 else {
        return XCTFail("Unexpected error: \(error)")
      }
      XCTAssertFalse((error as? LocalizedError)?.errorDescription?.isEmpty ?? true)
    }
  }

  func testFacadeTranslatesInvalidUTF8AndLocalizesError() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture) }
    let fileURL = fixture.appendingPathComponent("invalid.txt")
    try Data([0xff, 0xfe, 0xfd]).write(to: fileURL)

    XCTAssertThrowsError(
      try BoundedFileReader.utf8String(at: fileURL, maximumByteCount: 16)
    ) { error in
      guard case BoundedFileReadError.invalidUTF8(path: fileURL.path) = error else {
        return XCTFail("Unexpected error: \(error)")
      }
      XCTAssertFalse((error as? LocalizedError)?.errorDescription?.isEmpty ?? true)
    }
  }

  private func makeFixture() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("bounded-file-reader-facade-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}
