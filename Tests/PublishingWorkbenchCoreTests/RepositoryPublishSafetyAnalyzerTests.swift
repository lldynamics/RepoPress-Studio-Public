import XCTest

@testable import PublishingWorkbenchCore

final class RepositoryPublishSafetyAnalyzerTests: XCTestCase {
  func testBlocksStructuralDelete() {
    let report = analyze([
      entry(.deleted, "content/posts/2026/_index.md")
    ])

    XCTAssertEqual(report.blockers.map(\.code), [.structuralDelete])
    XCTAssertFalse(report.canPublish)
  }

  func testBlocksCrossSectionMove() {
    let report = analyze([
      entry(
        .renamed,
        "content/posts/2026/gallery/index.md",
        sourcePath: "content/gallery/trip/index.md"
      )
    ])

    XCTAssertEqual(report.blockers.map(\.code), [.crossSectionMove])
  }

  func testBlocksMassDelete() {
    let report = analyze(
      (0..<10).map {
        entry(.deleted, "content/projects/project-\($0).md")
      })

    XCTAssertEqual(report.blockers.map(\.code), [.massDelete])
  }

  func testWarnsForMassContentRewriteWithoutBlocking() {
    let report = analyze(
      (0..<25).map {
        entry(.modified, "content/posts/post-\($0).md")
      })

    XCTAssertEqual(report.warnings.map(\.code), [.massContentRewrite])
    XCTAssertTrue(report.canPublish)
  }

  func testWarnsWhenContentAndGuardChangeTogether() {
    let report = analyze([
      entry(.modified, "content/posts/article.md"),
      entry(.modified, "scripts/check.sh"),
    ])

    XCTAssertEqual(report.warnings.map(\.code), [.publishGuardChanged])
  }

  func testAllowsOrdinaryArticleAndImageChanges() {
    let report = analyze([
      entry(.modified, "content/posts/article.md"),
      entry(.added, "static/images/photo.png"),
    ])

    XCTAssertTrue(report.diagnostics.isEmpty)
    XCTAssertTrue(report.canPublish)
  }

  private func analyze(
    _ entries: [RepositoryWorktreePublishEntry]
  ) -> RepositoryPublishSafetyReport {
    var profile = SiteProfile.defaultProfile
    profile.siteKind = .zola
    profile.contentRoot = "content"
    let snapshot = RepositoryWorktreePublishSnapshot(
      repositoryRoot: "/tmp/site",
      gitCommonDirectory: "/tmp/site/.git",
      branch: "main",
      headSHA: "head",
      originURL: "https://example.com/owner/site.git",
      remoteBranchSHA: "head",
      statusFingerprint: "status",
      entries: entries
    )
    return RepositoryPublishSafetyAnalyzer().analyze(snapshot: snapshot, profile: profile)
  }

  private func entry(
    _ kind: RepositoryWorktreePublishEntryKind,
    _ path: String,
    sourcePath: String? = nil
  ) -> RepositoryWorktreePublishEntry {
    RepositoryWorktreePublishEntry(
      kind: kind,
      status: String(kind.rawValue.prefix(1)).uppercased(),
      path: path,
      sourcePath: sourcePath,
      byteSize: kind == .deleted ? 0 : 10,
      mode: kind == .deleted ? nil : "100644",
      blobOID: kind == .deleted ? nil : "blob"
    )
  }
}
