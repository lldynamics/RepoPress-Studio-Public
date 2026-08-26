import Foundation
import XCTest

import PublishingDomainContracts
@testable import PublishingGitCore

final class PublishPackageAssemblerTests: XCTestCase {
  func testAssemblesFilesAndStableReviewMetadata() throws {
    let draftID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    let builtAt = Date(timeIntervalSince1970: 1_700_000_000)
    let input = PublishPackageBuildInput(
      draftID: draftID,
      title: "Release Notes",
      draftSummary: "Summary",
      draftCoverAltText: "Cover alt",
      markdown: .init(
        repositoryPath: "content/posts/release-notes.md",
        content: "# Release Notes",
        expectedRemoteSHA: "markdown-sha"
      ),
      attachments: [
        .init(
          kind: .image,
          repositoryPath: "static/images/cover.png",
          sourceFilePath: "/tmp/cover.png",
          byteSize: 42,
          expectedRemoteSHA: "image-sha"
        ),
        .init(
          kind: .video,
          repositoryPath: "static/videos/demo.mp4",
          sourceFilePath: "/tmp/demo.mp4",
          byteSize: 84
        ),
      ],
      previousMarkdownDeletion: .init(
        repositoryPath: "content/posts/old-release-notes.md",
        expectedRemoteSHA: "old-sha",
        expectedContentSHA256: "old-content-sha",
        expectedGitBlobSHA: "old-blob-sha"
      ),
      publicationDate: utcDate(year: 2024, month: 1, day: 2),
      reviewSlug: "release-notes",
      builtAt: builtAt
    )

    let package = PublishPackageAssembler().assemble(input)

    XCTAssertEqual(package.draftID, draftID)
    XCTAssertEqual(package.title, "Release Notes")
    XCTAssertEqual(package.draftSummary, "Summary")
    XCTAssertEqual(package.draftCoverAltText, "Cover alt")
    XCTAssertEqual(package.markdownPath, "content/posts/release-notes.md")
    XCTAssertEqual(package.commitMessage, "Publish: Release Notes")
    XCTAssertEqual(package.reviewBranchName, "publish/release-notes-20240102")
    XCTAssertEqual(package.reviewTitle, "Publish Release Notes")
    XCTAssertEqual(package.builtAt, builtAt)
    XCTAssertEqual(package.reviewChecklist.count, 4)
    XCTAssertEqual(package.files.map(\.kind), [.markdown, .image, .video, .markdown])
    XCTAssertEqual(package.files.map(\.operation), [.upsert, .upsert, .upsert, .delete])
    XCTAssertEqual(package.files[0].expectedRemoteSHA, "markdown-sha")
    XCTAssertEqual(package.files[1].expectedRemoteSHA, "image-sha")
    XCTAssertEqual(package.files[3].expectedRemoteSHA, "old-sha")
    XCTAssertEqual(package.files[3].expectedContentSHA256, "old-content-sha")
    XCTAssertEqual(package.files[3].expectedGitBlobSHA, "old-blob-sha")
  }

  func testAssemblesPackageWithoutOptionalArtifacts() {
    let input = PublishPackageBuildInput(
      draftID: UUID(),
      title: "Minimal",
      markdown: .init(
        repositoryPath: "content/minimal.md",
        content: "# Minimal"
      ),
      publicationDate: utcDate(year: 2026, month: 8, day: 24),
      reviewSlug: "minimal"
    )

    let package = PublishPackageAssembler().assemble(input)

    XCTAssertEqual(package.files.count, 1)
    XCTAssertEqual(package.markdownFile?.content, "# Minimal")
    XCTAssertNil(package.draftSummary)
    XCTAssertNil(package.draftCoverAltText)
    XCTAssertEqual(package.reviewBranchName, "publish/minimal-20260824")
  }

  private func utcDate(year: Int, month: Int, day: Int) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar.date(from: DateComponents(year: year, month: month, day: day))!
  }
}
