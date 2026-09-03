import XCTest

@testable import PersonalSitePublisherMac

final class StructuralDraftRepairPresentationTests: XCTestCase {
  func testGroupsEighteenDuplicateRecordsByRepositoryPath() {
    let path = "content/posts/2026/_index.md"
    let records = (0..<18).map { index in
      StructuralDraftRepairDraftRecord(
        id: UUID(),
        title: "Legacy \(index)",
        repositoryPath: path
      )
    }

    let groups = StructuralDraftRepairPresentation.groups(for: records)

    XCTAssertEqual(groups.count, 1)
    XCTAssertEqual(groups.first?.repositoryPath, path)
    XCTAssertEqual(groups.first?.records.count, 18)
  }

  func testDefaultSelectionStartsEmptyAndCannotApply() {
    XCTAssertEqual(StructuralDraftRepairSelection.empty.draftIDs, [])
    XCTAssertEqual(StructuralDraftRepairSelection.empty.paths, [])
    XCTAssertFalse(StructuralDraftRepairSelection.empty.canApply)
  }

  func testOnlyFileSelectionCanReachConfirmationAndApply() {
    let selection = StructuralDraftRepairSelection(paths: ["content/_index.md"])

    XCTAssertTrue(
      StructuralDraftRepairPresentation.canAdvance(from: .preserveContent, selection: selection))
    XCTAssertTrue(
      StructuralDraftRepairPresentation.canAdvance(from: .restoreFiles, selection: selection))
    XCTAssertTrue(
      StructuralDraftRepairPresentation.canAdvance(from: .confirm, selection: selection))
    XCTAssertTrue(selection.canApply)
  }

  func testStepNavigationSupportsBacktrackingWithoutSelectionGate() {
    XCTAssertEqual(
      StructuralDraftRepairPresentation.nextStep(after: .preserveContent),
      .restoreFiles
    )
    XCTAssertEqual(
      StructuralDraftRepairPresentation.nextStep(after: .restoreFiles),
      .confirm
    )
    XCTAssertEqual(
      StructuralDraftRepairPresentation.previousStep(before: .confirm),
      .restoreFiles
    )
    XCTAssertTrue(
      StructuralDraftRepairPresentation.canAdvance(
        from: .restoreFiles,
        selection: .empty
      )
    )
    XCTAssertFalse(
      StructuralDraftRepairPresentation.canAdvance(
        from: .confirm,
        selection: .empty
      )
    )
  }
}
