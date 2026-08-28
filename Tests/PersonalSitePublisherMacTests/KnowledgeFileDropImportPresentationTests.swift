import PublishingWorkbenchCore
import XCTest

@testable import PersonalSitePublisherMac

final class KnowledgeFileDropImportPresentationTests: XCTestCase {
  func testRequestCarriesFirstDroppedFileAndDestinationTogether() throws {
    let fileURL = URL(fileURLWithPath: "/tmp/资料/../资料/图片.png")
    let folderID = UUID()

    let request = try XCTUnwrap(
      KnowledgeFileDropImportRequest.make(
        from: [fileURL],
        importDestination: .folder(folderID)
      )
    )

    XCTAssertEqual(request.sourceURLs, [fileURL.standardizedFileURL])
    XCTAssertEqual(request.importDestination, .folder(folderID))
  }

  func testRequestFiltersNonFileURLsAndDeduplicatesStandardizedPaths() throws {
    let fileURL = URL(fileURLWithPath: "/tmp/资料/图片.png")
    let equivalentFileURL = URL(fileURLWithPath: "/tmp/资料/./图片.png")
    let remoteURL = try XCTUnwrap(URL(string: "https://example.com/image.png"))

    let request = try XCTUnwrap(
      KnowledgeFileDropImportRequest.make(
        from: [remoteURL, fileURL, equivalentFileURL],
        importDestination: .preserveExisting
      )
    )

    XCTAssertEqual(request.sourceURLs, [fileURL.standardizedFileURL])
  }

  func testRequestRejectsDropWithoutLocalFiles() throws {
    let remoteURL = try XCTUnwrap(URL(string: "https://example.com/image.png"))

    XCTAssertNil(
      KnowledgeFileDropImportRequest.make(
        from: [remoteURL],
        importDestination: .preserveExisting
      )
    )
  }
}
