import XCTest

@testable import PersonalSitePublisherMac
@testable import PublishingWorkbenchCore

final class ReleaseHistoryPresentationTests: XCTestCase {
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
