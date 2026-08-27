import Foundation
import XCTest
@testable import PublishingWorkbenchCore

final class KnowledgeImportPreviewExecutionPolicyTests: XCTestCase {
  func testPDFPreviewUsesBackgroundPriority() {
    XCTAssertEqual(
      KnowledgeImportPreviewExecutionPolicy.priority(
        for: [URL(fileURLWithPath: "/tmp/scanned-book.PDF")]
      ),
      .background
    )
  }

  func testDirectoryContainingPDFUsesBackgroundPriority() {
    XCTAssertEqual(
      KnowledgeImportPreviewExecutionPolicy.priority(
        for: [URL(fileURLWithPath: "/tmp/knowledge")],
        sourceTreeContainsPDF: true
      ),
      .background
    )
  }

  func testOrdinaryTextPreviewKeepsInteractivePriority() {
    XCTAssertEqual(
      KnowledgeImportPreviewExecutionPolicy.priority(
        for: [URL(fileURLWithPath: "/tmp/notes.md")]
      ),
      .userInitiated
    )
  }
}
