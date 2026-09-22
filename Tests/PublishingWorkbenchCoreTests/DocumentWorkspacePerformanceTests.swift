import Combine
import Foundation
import XCTest

@testable import PublishingWorkbenchCore

/// User-visible performance invariants for the long-running chat and writing
/// surfaces. These are trend-only measurements: the assertions describe
/// observation boundaries, while timings are retained in the test log for
/// comparisons between revisions on the same machine.
@MainActor
final class DocumentWorkspacePerformanceTests: XCTestCase {
  private func makeTemporaryStore(_ prefix: String) throws -> (WorkbenchStore, URL) {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let fileURL = directory.appendingPathComponent("workspace.json")
    return (WorkbenchStore(persistence: WorkbenchPersistence(fileURL: fileURL)), directory)
  }

  func testLongAIChatUpdatesStayIsolatedFromDraftListAndEditorContext() throws {
    let (store, temporaryDirectory) = try makeTemporaryStore(
      "document-workspace-chat-performance"
    )
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

    let drafts = [
      ArticleDraft(
        siteProfileID: store.activeProfileID,
        title: "正在编辑的文章",
        slug: "editing-article",
        bodyMarkdown: "编辑中的正文"
      ),
      ArticleDraft(
        siteProfileID: store.activeProfileID,
        title: "旁边的文章",
        slug: "neighbor-article",
        bodyMarkdown: "另一篇正文"
      ),
    ]
    store.setDrafts(drafts)
    store.selectDraft(drafts[0].id)
    let stagedBuffer = DraftBodyEditorBuffer(
      draftID: drafts[0].id,
      bodyMarkdown: "尚未保存的编辑上下文",
      revision: 1,
      isDirty: true
    )
    store.publishingStore.documentSession.setDraftBodyEditorBuffer(
      stagedBuffer,
      for: drafts[0].id,
      notifyObservers: false
    )

    let messageBody = String(repeating: "长会话内容 ", count: 150)
    var messages = (0..<1_000).map { index in
      AIPublishingChatMessage(
        role: index.isMultiple(of: 2) ? .user : .assistant,
        content: "第\(index)条：\(messageBody)"
      )
    }
    store.setAIChatMessages(messages)

    let facade = WorkbenchAIChatFeatureFacade(store: store, draftID: drafts[0].id)
    let draftList = store.draftList
    var chatChanges = 0
    var documentCollectionPublications = 0
    var draftListPublications = 0
    let chatCancellable = facade.objectWillChange.sink { chatChanges += 1 }
    let documentsCancellable = store.publishingStore.documents.$drafts
      .dropFirst()
      .sink { _ in documentCollectionPublications += 1 }
    let listCancellable = draftList.presentationDidChange
      .dropFirst()
      .sink { _ in draftListPublications += 1 }

    let selectedDraftID = store.selectedDraftID
    let initialDrafts = store.publishingStore.documents.drafts
    let initialListRevision = draftList.presentationRevision
    let initialBuffer = store.draftBodyEditorBuffer(for: drafts[0].id)
    var sampleMilliseconds: [Double] = []

    for sample in 0..<7 {
      let start = DispatchTime.now().uptimeNanoseconds
      for update in 0..<100 {
        messages[messages.count - 1].content =
          "第999条：\(messageBody) sample=\(sample) update=\(update)"
        store.setAIChatMessages(messages)
      }
      let elapsed = DispatchTime.now().uptimeNanoseconds - start
      sampleMilliseconds.append(Double(elapsed) / 1_000_000)
    }

    XCTAssertEqual(chatChanges, 700)
    XCTAssertEqual(documentCollectionPublications, 0)
    XCTAssertEqual(draftListPublications, 0)
    XCTAssertEqual(store.selectedDraftID, selectedDraftID)
    XCTAssertEqual(store.publishingStore.documents.drafts, initialDrafts)
    XCTAssertEqual(draftList.presentationRevision, initialListRevision)
    XCTAssertEqual(store.draftBodyEditorBuffer(for: drafts[0].id), initialBuffer)
    XCTAssertEqual(store.aiChatMessages.count, 1_000)
    XCTAssertTrue(store.aiChatMessages.last?.content.contains("sample=6 update=99") == true)
    print(
      "PERF[DocumentWorkspacePerformanceTests] long-ai-chat-100-updates "
        + "samples_ms=\(sampleMilliseconds.map { String(format: "%.2f", $0) }.joined(separator: ",")) "
        + "messages=1000 message_utf16=\((messageBody as NSString).length) "
        + "samples=7 trend_only=true"
    )

    withExtendedLifetime((chatCancellable, documentsCancellable, listCancellable)) {}
  }

  func testBodyOnlyBuffersOnThousandDraftsDoNotBroadcastDocumentCollection() throws {
    let (store, temporaryDirectory) = try makeTemporaryStore(
      "document-workspace-buffer-performance"
    )
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
    let drafts = (0..<1_000).map { index in
      ArticleDraft(
        siteProfileID: store.activeProfileID,
        title: "草稿 \(index)",
        slug: "draft-\(index)",
        bodyMarkdown: "固定正文"
      )
    }
    store.setDrafts(drafts)
    let draft = try XCTUnwrap(drafts.first)
    let draftList = store.draftList
    var documentCollectionPublications = 0
    var draftListPublications = 0
    let documentsCancellable = store.publishingStore.documents.$drafts
      .dropFirst()
      .sink { _ in documentCollectionPublications += 1 }
    let listCancellable = draftList.presentationDidChange
      .dropFirst()
      .sink { _ in draftListPublications += 1 }
    let initialDrafts = store.publishingStore.documents.drafts
    let initialListRevision = draftList.presentationRevision
    var sampleMilliseconds: [Double] = []
    var revision = store.draftBodyEditorBuffer(for: draft.id).revision

    for sample in 0..<7 {
      let start = DispatchTime.now().uptimeNanoseconds
      for update in 0..<100 {
        let result = store.stageDraftBody(
          "实时正文 sample=\(sample) update=\(update)",
          for: draft.id,
          baseRevision: revision
        )
        XCTAssertTrue(result?.wasAccepted == true)
        revision = result?.buffer.revision ?? revision
      }
      let elapsed = DispatchTime.now().uptimeNanoseconds - start
      sampleMilliseconds.append(Double(elapsed) / 1_000_000)
    }

    XCTAssertEqual(documentCollectionPublications, 0)
    XCTAssertEqual(draftListPublications, 0)
    XCTAssertEqual(store.publishingStore.documents.drafts, initialDrafts)
    XCTAssertEqual(draftList.presentationRevision, initialListRevision)
    XCTAssertEqual(store.draftBodyEditorBuffer(for: draft.id).revision, 700)
    XCTAssertTrue(store.draftBodyEditorBuffer(for: draft.id).isDirty)
    print(
      "PERF[DocumentWorkspacePerformanceTests] body-buffer-100-updates "
        + "samples_ms=\(sampleMilliseconds.map { String(format: "%.2f", $0) }.joined(separator: ",")) "
        + "drafts=1000 samples=7 trend_only=true"
    )

    withExtendedLifetime((documentsCancellable, listCancellable)) {}
  }
}
