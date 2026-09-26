import Foundation
import PublishingBackupCore
import PublishingDomainContracts
import PublishingKnowledgeCore
import XCTest

@testable import PublishingWorkbenchCore

@MainActor
final class WorkspaceExchangeMetadataRoundTripTests: XCTestCase {
  func testAttachmentMetadataSurvivesImportPersistenceAndExport() async throws {
    let samples: [(String?, String?)] = [
      ("  中文替代文字 👩🏽‍💻 e\u{301}  ", "第一行\n第二行：图片说明 🏝️"),
      (nil, nil),
      ("", ""),
    ]

    for (altText, caption) in samples {
      let fixtureURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/portable-workspace-v1.json")
      var payload = try WorkspaceExchangeCodec.decode(Data(contentsOf: fixtureURL)).payload
      payload.drafts[0].attachments[0].altText = altText
      payload.drafts[0].attachments[0].caption = caption
      let sourceDraft = try XCTUnwrap(payload.drafts.first)
      let sourceAttachment = try XCTUnwrap(sourceDraft.attachments.first)
      let sourceProfileID = try XCTUnwrap(payload.profiles.first?.id)
      let data = try WorkspaceExchangeCodec.encode(payload)

      let rootURL = try TestWorkbenchFactory.temporaryDirectoryURL(
        prefix: "ExchangeMetadataRoundTrip")
      defer { try? FileManager.default.removeItem(at: rootURL) }
      let persistenceURL = rootURL.appendingPathComponent("workbench.json")
      let knowledgeURL = rootURL.appendingPathComponent("KnowledgeLibrary")
      let attachmentRoot = rootURL.appendingPathComponent("ManagedAttachments", isDirectory: true)

      do {
        let store = WorkbenchStore(
          persistence: WorkbenchPersistence(fileURL: persistenceURL),
          knowledgeLibraryService: KnowledgeLibraryService(rootURL: knowledgeURL),
          managedAttachmentFileStore: ManagedAttachmentFileStore(rootDirectoryURL: attachmentRoot)
        )
        let preview = try await store.previewWorkspaceExchange(data: data)
        let imported = try await store.importWorkspaceExchange(
          preview, profileMappings: [sourceProfileID: .importAsNewProfile])
        XCTAssertEqual(imported, 1)
      }

      let reopened = WorkbenchStore(
        persistence: WorkbenchPersistence(fileURL: persistenceURL),
        knowledgeLibraryService: KnowledgeLibraryService(rootURL: knowledgeURL),
        managedAttachmentFileStore: ManagedAttachmentFileStore(rootDirectoryURL: attachmentRoot)
      )
      let restored = try XCTUnwrap(reopened.drafts.first { $0.title == sourceDraft.title })
      let restoredAttachment = try XCTUnwrap(restored.attachments.first)
      XCTAssertEqual(Array(restoredAttachment.altText.utf8), Array((altText ?? "").utf8))
      XCTAssertEqual(Array(restoredAttachment.caption.utf8), Array((caption ?? "").utf8))

      let exported = try await reopened.makeWorkspaceExchangeData()
      let exportedPackage = try WorkspaceExchangeCodec.decode(exported)
      let exportedDraft = try XCTUnwrap(
        exportedPackage.payload.drafts.first { $0.id == restored.id })
      let exportedAttachment = try XCTUnwrap(exportedDraft.attachments.first)
      // Native models use empty strings for absent optional exchange metadata.
      XCTAssertEqual(Array((exportedAttachment.altText ?? "").utf8), Array((altText ?? "").utf8))
      XCTAssertEqual(Array((exportedAttachment.caption ?? "").utf8), Array((caption ?? "").utf8))
      XCTAssertEqual(exportedAttachment.bytes, sourceAttachment.bytes)
      XCTAssertEqual(exportedAttachment.sha256, sourceAttachment.sha256)
      XCTAssertEqual(exportedAttachment.relativePublishPath, sourceAttachment.relativePublishPath)
      XCTAssertEqual(exportedDraft.bodyMarkdown, sourceDraft.bodyMarkdown)
      XCTAssertEqual(exportedDraft.coverAttachmentID, exportedAttachment.id)
      XCTAssertNotEqual(restored.id, sourceDraft.id)
      XCTAssertNotEqual(exportedAttachment.id, sourceAttachment.id)
    }
  }
}
