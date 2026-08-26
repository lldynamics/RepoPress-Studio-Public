import Foundation
import XCTest

@testable import PublishingGitCore

final class GitWorkingTreeModelsTests: XCTestCase {
  func testChangedFilePreservesIdentityAndNormalizesDisplayPath() throws {
    let file = RepositoryChangedFile(
      status: "R ",
      path: "content/old.md ->  content/new.md  ",
      kind: .renamed,
      lineDiff: "@@ -1 +1 @@"
    )

    XCTAssertEqual(file.id, "R content/old.md ->  content/new.md  ")
    XCTAssertEqual(file.displayPath, "content/new.md")
    XCTAssertEqual(file.lineDiff, "@@ -1 +1 @@")
  }

  func testWorkingTreeModelsRoundTripThroughCodableAndRemainHashable() throws {
    let file = RepositoryChangedFile(
      status: " M",
      path: "content/posts/hello.md",
      kind: .modified,
      lineDiff: nil
    )
    let fileData = try JSONEncoder().encode(file)
    let decodedFile = try JSONDecoder().decode(RepositoryChangedFile.self, from: fileData)
    XCTAssertEqual(decodedFile, file)
    XCTAssertEqual(Set([file]), Set([decodedFile]))

    let snapshot = RepositoryFileSnapshot(
      refName: "origin/main",
      repositoryPath: "content/posts/hello.md",
      content: "# Hello",
      repositorySHA: "0123456789abcdef"
    )
    let snapshotData = try JSONEncoder().encode(snapshot)
    XCTAssertEqual(try JSONDecoder().decode(RepositoryFileSnapshot.self, from: snapshotData), snapshot)
  }

  func testStructuredPairPreservesExactPathsAndLegacyDisplayPayload() throws {
    let source = "content/旧 -> source\n文件.md"
    let destination = "content/新 -> destination\n文件.md"
    let file = RepositoryChangedFile(
      status: "R100",
      changedPath: .sourceAndDestination(source: source, destination: destination),
      kind: .renamed
    )

    XCTAssertEqual(file.sourcePath, source)
    XCTAssertEqual(file.destinationPath, destination)
    XCTAssertEqual(file.path, source + " -> " + destination)
    XCTAssertEqual(file.displayPath, destination)

    let decoded = try JSONDecoder().decode(
      RepositoryChangedFile.self,
      from: JSONEncoder().encode(file)
    )
    XCTAssertEqual(decoded, file)
    XCTAssertEqual(decoded.sourcePath, source)
    XCTAssertEqual(decoded.destinationPath, destination)
  }

  func testStructuredEncodingRemainsReadableByLegacyFourFieldDecoder() throws {
    let source = "content/old -> source.md"
    let destination = "content/new -> destination.md"
    let file = RepositoryChangedFile(
      status: "C075",
      sourcePath: source,
      destinationPath: destination,
      kind: .other,
      lineDiff: "copy patch"
    )
    let data = try JSONEncoder().encode(file)
    let object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: data) as? [String: Any]
    )

    XCTAssertEqual(object["path"] as? String, source + " -> " + destination)
    XCTAssertEqual(object["sourcePath"] as? String, source)
    XCTAssertEqual(object["destinationPath"] as? String, destination)

    let legacy = try JSONDecoder().decode(LegacyChangedFilePayload.self, from: data)
    XCTAssertEqual(legacy.status, "C075")
    XCTAssertEqual(legacy.path, source + " -> " + destination)
    XCTAssertEqual(legacy.kind, .other)
    XCTAssertEqual(legacy.lineDiff, "copy patch")
  }

  func testLegacySingleFilenameContainingArrowDoesNotBecomeAPair() {
    let path = "content/filename -> literal.md"
    let file = RepositoryChangedFile(status: " M", path: path, kind: .modified)

    XCTAssertNil(file.sourcePath)
    XCTAssertEqual(file.destinationPath, path)
    XCTAssertEqual(file.displayPath, path)
  }

  func testStructuredPairsWithSameLegacyPathRemainDistinctAndHaveDistinctIDs() {
    let first = RepositoryChangedFile(
      status: "R100",
      changedPath: .sourceAndDestination(
        source: "content/old -> left.md",
        destination: "content/new.md"
      ),
      kind: .renamed
    )
    let second = RepositoryChangedFile(
      status: "R100",
      changedPath: .sourceAndDestination(
        source: "content/old",
        destination: "left.md -> content/new.md"
      ),
      kind: .renamed
    )

    XCTAssertEqual(first.path, second.path)
    XCTAssertNotEqual(first, second)
    XCTAssertNotEqual(first.id, second.id)
  }

  func testDecoderRejectsIncompleteNullOrConflictingStructuredPathPayloads() throws {
    let base: [String: Any] = [
      "status": "R100",
      "path": "content/old.md -> content/new.md",
      "kind": "renamed",
    ]
    let invalidPayloads: [[String: Any]] = [
      base.merging(["sourcePath": "content/old.md"], uniquingKeysWith: { _, new in new }),
      base.merging(["destinationPath": "content/new.md"], uniquingKeysWith: { _, new in new }),
      base.merging(["sourcePath": NSNull(), "destinationPath": "content/new.md"], uniquingKeysWith: { _, new in new }),
      base.merging(["sourcePath": "content/old.md", "destinationPath": NSNull()], uniquingKeysWith: { _, new in new }),
      base.merging(["sourcePath": "content/other.md", "destinationPath": "content/new.md"], uniquingKeysWith: { _, new in new }),
    ]

    for payload in invalidPayloads {
      let data = try JSONSerialization.data(withJSONObject: payload)
      XCTAssertThrowsError(try JSONDecoder().decode(RepositoryChangedFile.self, from: data))
    }
  }

  func testLegacyFourFieldPayloadRemainsReadableForRenameAndCopy() throws {
    let payloads = [
      "{\"status\":\"R100\",\"path\":\"old.md -> new.md\",\"kind\":\"renamed\",\"lineDiff\":null}",
      "{\"status\":\"C075\",\"path\":\"source.md -> copy.md\",\"kind\":\"other\",\"lineDiff\":null}",
    ]

    for payload in payloads {
      let file = try JSONDecoder().decode(
        RepositoryChangedFile.self,
        from: Data(payload.utf8)
      )
      XCTAssertNotNil(file.sourcePath)
      XCTAssertEqual(file.path, file.sourcePath! + " -> " + file.destinationPath)
    }
  }

  func testLegacyPairFallbackUsesTheLastSeparator() throws {
    let payload = "{\"status\":\"R100\",\"path\":\"old -> source.md -> new.md\",\"kind\":\"renamed\"}"
    let file = try JSONDecoder().decode(
      RepositoryChangedFile.self,
      from: Data(payload.utf8)
    )

    XCTAssertEqual(file.sourcePath, "old -> source.md")
    XCTAssertEqual(file.destinationPath, "new.md")
  }

  func testFetchResultCarriesStatusAndOptionalRemoteContext() throws {
    let result = RepositoryFetchResult(
      status: .skipped,
      remoteName: nil,
      upstreamName: "origin/main",
      message: "upstream is not configured"
    )

    XCTAssertEqual(result.status, .skipped)
    XCTAssertNil(result.remoteName)
    XCTAssertEqual(result.upstreamName, "origin/main")
    XCTAssertEqual(result.message, "upstream is not configured")
    XCTAssertEqual(
      try JSONDecoder().decode(RepositoryFetchResult.self, from: JSONEncoder().encode(result)),
      result
    )
  }

  private struct LegacyChangedFilePayload: Codable {
    var status: String
    var path: String
    var kind: RepositoryChangeKind
    var lineDiff: String?
  }
}
