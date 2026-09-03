import XCTest

@testable import PersonalSitePublisherMac
@testable import PublishingWorkbenchCore

final class RepositoryStructuralChangePresentationTests: XCTestCase {
  func testSectionsAreSeparatedWithoutLosingChangesOrImportingDeletedArticles() {
    let files: [RepositoryChangedFile] = [
      file("content/posts/_INDEX.MD"), file("content/posts/_index.markdown"),
      file("content/posts/_index.mdx"), file("content/posts/post/index.md"),
      file("content/posts/removed.md", kind: .deleted),
      file("static/img/photo.png"), file("config.toml"), file("notes.txt"),
    ]
    let presentation = makePresentation(files)
    XCTAssertEqual(presentation.structuralCount, 3)
    XCTAssertEqual(presentation.articleCount, 2)
    XCTAssertEqual(presentation.imageCount, 1)
    XCTAssertEqual(presentation.configurationCount, 1)
    XCTAssertEqual(presentation.otherCount, 1)
    XCTAssertEqual(presentation.totalCount, files.count)
    XCTAssertEqual(presentation.publishRelevantCount, 7)
    XCTAssertEqual(
      presentation.importableArticles.map(\.destinationPath), ["content/posts/post/index.md"])
    XCTAssertEqual(
      Set(RepositoryDisplayChangeRole.allCases.flatMap { presentation.files(for: $0) }.map(\.id)),
      Set(files.map(\.id)))
  }

  func testBothRenameEndpointsAreConsideredAndIdentityIsPreserved() {
    let files = [
      RepositoryChangedFile(
        status: "R", sourcePath: "content/_index.md", destinationPath: "notes.txt", kind: .renamed),
      RepositoryChangedFile(
        status: "R", sourcePath: "content/old.md", destinationPath: "content/_index.md",
        kind: .renamed),
    ]
    let presentation = makePresentation(files)
    XCTAssertEqual(presentation.files(for: .structure), files)
    XCTAssertTrue(presentation.importableArticles.isEmpty)
  }

  func testOnlySectionBasedGeneratorsSeparateStructure() {
    for kind in [SiteKind.zola, .hugo] {
      XCTAssertEqual(makePresentation([file("content/_index.md")], kind: kind).structuralCount, 1)
    }
    let other = makePresentation(
      [file("content/_index.md"), file("content/index.md")], kind: .jekyll)
    XCTAssertEqual(other.structuralCount, 0)
    XCTAssertEqual(other.articleCount, 2)
  }

  func testRemoteAndLocalUseSameClassificationWithoutMixingSources() {
    let local = [file("content/local.md"), file("content/_index.md")]
    let remote = [file("content/remote.md"), file("content/year/_index.mdx")]
    var profile = SiteProfile.defaultProfile
    profile.siteKind = .zola
    profile.contentRoot = "content"
    let report = makeReport(local, remote: remote)
    let presentation = RepositoryStructuralChangePresentation(
      report: report, profile: profile, isRemote: true)
    XCTAssertEqual(presentation.files(for: .article), [remote[0]])
    XCTAssertEqual(presentation.files(for: .structure), [remote[1]])
    XCTAssertEqual(presentation.totalCount, 2)
  }

  private func file(_ path: String, kind: RepositoryChangeKind = .modified) -> RepositoryChangedFile
  {
    RepositoryChangedFile(status: kind == .deleted ? " D" : " M", path: path, kind: kind)
  }

  private func makePresentation(_ files: [RepositoryChangedFile], kind: SiteKind = .zola)
    -> RepositoryStructuralChangePresentation
  {
    var profile = SiteProfile.defaultProfile
    profile.siteKind = kind
    profile.contentRoot = "content"
    profile.assetRoot = "static/img"
    return RepositoryStructuralChangePresentation(report: makeReport(files), profile: profile)
  }

  private func makeReport(_ files: [RepositoryChangedFile], remote: [RepositoryChangedFile] = [])
    -> RepositoryScanReport
  {
    RepositoryScanReport(
      rootPath: "/tmp/example", detectedKind: .zola, expectedKind: .zola,
      hasGitDirectory: true, contentRootExists: true, assetRootExists: true,
      markdownFileCount: 0, imageFileCount: 0, changedFiles: files,
      remoteChangedFiles: remote, preflightIssues: [])
  }
}
