import AppKit
import SwiftUI
import XCTest

@testable import PersonalSitePublisherMac
@testable import PublishingWorkbenchCore

final class ReleaseHistoryPresentationTests: XCTestCase {
  func testSourcePreviewRequiresExplicitExistingRecordSite() {
    let profile = SiteProfile.defaultProfile
    var record = ReleaseRecord(title: "Old release", summary: "")
    XCTAssertNil(DeploymentSourceContext.profile(for: record, in: [profile]))
    record.siteProfileID = UUID()
    XCTAssertNil(DeploymentSourceContext.profile(for: record, in: [profile]))
    record.siteProfileID = profile.id
    XCTAssertEqual(DeploymentSourceContext.profile(for: record, in: [profile]), profile)
  }

  func testSourcePreviewRequestRejectsConfigurationChangesAndQuickHide() {
    let profile = SiteProfile.defaultProfile
    let request = DeploymentSourceRequest(
      profile: profile,
      entry: DeploymentLogEntry(level: .error, source: "test", message: "failure", filePath: "a.md")
    )
    XCTAssertTrue(request.isValid(activeProfile: profile, canUseProtectedWorkbench: true))
    XCTAssertFalse(request.isValid(activeProfile: profile, canUseProtectedWorkbench: false))
    var changed = profile
    changed.localRepositoryRootPath = "/another/repository"
    XCTAssertFalse(request.isValid(activeProfile: changed, canUseProtectedWorkbench: true))
  }

  @MainActor
  func testSourcePreviewUsesReadOnlySelectableTextAndSelectsReportedLine() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("SourcePreviewView-\(UUID().uuidString)").resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = "first\n错误😀\nlast"
    try source.write(
      to: root.appendingPathComponent("article.md"), atomically: true, encoding: .utf8)
    let document = try DeploymentSourceFileService().open(
      profile: SiteProfile(name: "Preview", localRepositoryRootPath: root.path),
      entry: DeploymentLogEntry(
        level: .error, source: "test", message: "failure", filePath: "article.md", line: 2))
    let host = NSHostingView(rootView: DeploymentSourceTextView(document: document))
    host.frame = NSRect(x: 0, y: 0, width: 480, height: 240)
    host.layoutSubtreeIfNeeded()
    func findText(in view: NSView) -> NSTextView? {
      if let text = view as? NSTextView { return text }
      return view.subviews.lazy.compactMap { findText(in: $0) }.first
    }
    let text = try XCTUnwrap(findText(in: host))
    XCTAssertEqual(text.string, source)
    XCTAssertFalse(text.isEditable)
    XCTAssertTrue(text.isSelectable)
    XCTAssertEqual(text.selectedRange(), document.selectionRange)
    XCTAssertEqual(text.accessibilityIdentifier(), "deployment-source-text")
  }

  func testRepeatedFailuresGroupByStableStatusMessageAtFirstOccurrence() {
    let first = failure(title: "第一次", message: "构建失败：找不到 Hugo 模板", at: 10)
    let success = entry(title: "成功", status: .succeeded, message: "已上线", at: 9)
    let second = failure(title: "第二次", message: "构建失败：找不到 Hugo 模板", at: 8)
    let single = failure(title: "单次", message: "部署超时", at: 7)

    let presentations = ReleaseHistoryPresentation.records(for: [first, success, second, single])

    XCTAssertEqual(presentations.count, 3)
    guard case .failureGroup(let group) = presentations[0] else {
      return XCTFail("The first repeated failure should be a group")
    }
    XCTAssertEqual(group.cause, "构建失败：找不到 Hugo 模板")
    XCTAssertEqual(group.entries.map(\.id), [first.id, second.id])
    XCTAssertEqual(group.latestDate, first.record.createdAt)
    guard case .entry(let presentedSuccess) = presentations[1],
      case .entry(let presentedSingleFailure) = presentations[2]
    else {
      return XCTFail("Non-repeated records should preserve their position")
    }
    XCTAssertEqual(presentedSuccess.id, success.id)
    XCTAssertEqual(presentedSingleFailure.id, single.id)
  }

  func testFailureCauseFallsBackToReleaseMessageWhenNoDeploymentSignalExists() {
    let value = failure(title: "失败", message: "  远端写入失败\n请检查权限  ", at: 1)

    XCTAssertEqual(
      ReleaseHistoryPresentation.failureCause(value),
      "远端写入失败 请检查权限"
    )
  }

  func testSuccessfulEntryWithMatchingMessageIsNotAbsorbedByFailureGroup() {
    let success = entry(title: "成功", status: .succeeded, message: "同一状态文案", at: 12)
    let firstFailure = failure(title: "失败一", message: "同一状态文案", at: 11)
    let secondFailure = failure(title: "失败二", message: "同一状态文案", at: 10)

    let presentations = ReleaseHistoryPresentation.records(
      for: [success, firstFailure, secondFailure]
    )

    XCTAssertEqual(presentations.count, 2)
    guard case .entry(let presentedSuccess) = presentations[0],
      case .failureGroup(let group) = presentations[1]
    else {
      return XCTFail("成功记录应保留，重复失败应在首个失败位置分组")
    }
    XCTAssertEqual(presentedSuccess.id, success.id)
    XCTAssertEqual(group.entries.map(\.id), [firstFailure.id, secondFailure.id])
  }

  func testWithdrawnReviewRemainsAnOrdinaryHistoryEntry() {
    let withdrawn = entry(
      title: "审核已撤回",
      status: .reviewWithdrawn,
      message: "PR/MR 已撤回，未合并到目标分支，也未触发部署。",
      at: 12
    )
    let firstFailure = failure(title: "失败一", message: "部署超时", at: 11)
    let secondFailure = failure(title: "失败二", message: "部署超时", at: 10)

    let presentations = ReleaseHistoryPresentation.records(
      for: [withdrawn, firstFailure, secondFailure]
    )

    XCTAssertEqual(presentations.count, 2)
    guard case .entry(let entry) = presentations.first else {
      return XCTFail("Expected withdrawn review to remain a standalone entry")
    }
    XCTAssertEqual(entry.status, .reviewWithdrawn)
    XCTAssertEqual(entry.status.localizedDisplayName, "审核已撤回")
  }

  private func failure(title: String, message: String, at seconds: TimeInterval)
    -> ReleaseLedgerEntry
  {
    entry(title: title, status: .failed, message: message, at: seconds)
  }

  private func entry(
    title: String,
    status: ReleaseLedgerStatus,
    message: String,
    at seconds: TimeInterval
  ) -> ReleaseLedgerEntry {
    ReleaseLedgerEntry(
      id: UUID(),
      record: ReleaseRecord(
        title: title,
        summary: "发布摘要",
        markdownPath: "content/\(title).md",
        createdAt: Date(timeIntervalSince1970: seconds)
      ),
      status: status,
      statusMessage: message,
      deploymentStatus: nil,
      rollbackDraft: nil
    )
  }
}
