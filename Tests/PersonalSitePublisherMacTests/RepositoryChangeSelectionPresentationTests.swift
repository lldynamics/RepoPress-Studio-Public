import PublishingGitCore
import XCTest
@testable import PersonalSitePublisherMac

final class RepositoryChangeSelectionPresentationTests: XCTestCase {
  func testSelectionResolvesWithinItsOwnSource() {
    let local = RepositoryChangedFile(
      status: " M",
      path: "content/local.md",
      kind: .modified,
      lineDiff: "-old\n+new"
    )
    let remote = RepositoryChangedFile(
      status: " M",
      path: "content/remote.md",
      kind: .modified
    )
    let selection = RepositoryChangedFileSelection(source: .remote, file: remote)

    XCTAssertEqual(
      RepositoryChangedFileSelectionPresentation.selectedFile(
        for: selection,
        localFiles: [local],
        remoteFiles: [remote]
      ),
      remote
    )
  }

  func testSelectionClearsWhenTheNextScanNoLongerContainsTheFile() {
    let local = RepositoryChangedFile(status: " M", path: "content/local.md", kind: .modified)
    let selection = RepositoryChangedFileSelection(source: .local, file: local)

    XCTAssertNil(
      RepositoryChangedFileSelectionPresentation.reconciledSelection(
        selection,
        localFiles: [],
        remoteFiles: []
      )
    )
  }

  func testSelectionSurvivesAnUnrelatedScanChange() {
    let selected = RepositoryChangedFile(status: " M", path: "content/selected.md", kind: .modified)
    let additional = RepositoryChangedFile(status: "??", path: "static/new.png", kind: .untracked)
    let selection = RepositoryChangedFileSelection(source: .local, file: selected)

    XCTAssertEqual(
      RepositoryChangedFileSelectionPresentation.reconciledSelection(
        selection,
        localFiles: [additional, selected],
        remoteFiles: []
      ),
      selection
    )
  }

  func testSelectionSurvivesStatusAndDiffRefreshForTheSamePath() {
    let original = RepositoryChangedFile(
      status: " M",
      path: "content/selected.md",
      kind: .modified,
      lineDiff: "-old"
    )
    let refreshed = RepositoryChangedFile(
      status: "M ",
      path: "content/selected.md",
      kind: .modified,
      lineDiff: "-old\n+new"
    )
    let selection = RepositoryChangedFileSelection(source: .local, file: original)

    XCTAssertEqual(
      RepositoryChangedFileSelectionPresentation.selectedFile(
        for: selection,
        localFiles: [refreshed],
        remoteFiles: []
      ),
      refreshed
    )
    XCTAssertEqual(
      RepositoryChangedFileSelectionPresentation.reconciledSelection(
        selection,
        localFiles: [refreshed],
        remoteFiles: []
      ),
      selection
    )
  }
}
