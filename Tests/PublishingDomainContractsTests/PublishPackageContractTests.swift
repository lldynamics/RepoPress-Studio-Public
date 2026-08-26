import Foundation
import XCTest

@testable import PublishingDomainContracts

final class PublishPackageContractTests: XCTestCase {
  func testLegacyFilePayloadDefaultsToUpsert() throws {
    let payload = Data(
      #"{"kind":"markdown","repositoryPath":"content/posts/legacy.md","content":"body","byteSize":4}"#.utf8
    )

    let file = try JSONDecoder().decode(PublishPackageFile.self, from: payload)

    XCTAssertEqual(file.operation, .upsert)
    XCTAssertEqual(file.repositoryPath, "content/posts/legacy.md")
  }

  func testFileRoundTripPreservesAllIntegrityEvidence() throws {
    let expected = PublishPackageFile(
      kind: .image,
      repositoryPath: "static/images/cover.png",
      sourceFilePath: "/tmp/cover.png",
      byteSize: 42,
      expectedRemoteSHA: "remote-sha",
      expectedContentSHA256: "content-sha256",
      expectedGitBlobSHA: "git-blob-sha"
    )

    let data = try JSONEncoder().encode(expected)
    let decoded = try JSONDecoder().decode(PublishPackageFile.self, from: data)

    XCTAssertEqual(decoded, expected)
  }

  func testPackageRoundTripPreservesMarkdownProjection() throws {
    let package = PublishPackage(
      id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
      draftID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
      title: "Architecture",
      draftSummary: "Summary",
      draftCoverAltText: "Cover",
      markdownPath: "content/posts/architecture.md",
      files: [
        PublishPackageFile(
          kind: .markdown,
          repositoryPath: "content/posts/architecture.md",
          content: "# Architecture"
        ),
        PublishPackageFile(
          kind: .markdown,
          operation: .delete,
          repositoryPath: "content/posts/old.md",
          expectedRemoteSHA: "old-sha"
        ),
      ],
      commitMessage: "Publish: Architecture",
      reviewBranchName: "publish/architecture-20260824",
      reviewTitle: "Publish Architecture",
      reviewChecklist: ["Preview checked"],
      builtAt: Date(timeIntervalSince1970: 1_700_000_000)
    )

    let data = try JSONEncoder().encode(package)
    let decoded = try JSONDecoder().decode(PublishPackage.self, from: data)

    XCTAssertEqual(decoded, package)
    XCTAssertEqual(decoded.markdownFile?.repositoryPath, package.markdownPath)
    XCTAssertEqual(decoded.markdownFile?.operation, .upsert)
  }
}
