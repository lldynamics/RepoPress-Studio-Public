import XCTest

@testable import PersonalSitePublisherMac
@testable import PublishingWorkbenchCore

private actor DraftVersionComparisonInvocationRecorder {
  private var invocationCount = 0

  func compare(_ previous: ArticleDraft, _ current: ArticleDraft) -> DraftVersionComparison {
    invocationCount += 1
    return DraftVersionComparisonService().compare(previous: previous, current: current)
  }

  func count() -> Int {
    invocationCount
  }
}

@MainActor
final class DraftVersionComparisonLoaderTests: XCTestCase {
  func testLoaderCachesEachSourceTargetPairAcrossRepeatedSelection() async {
    let profile = SiteProfile.defaultProfile
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "版本",
      bodyMarkdown: "起点"
    )
    let source = DraftVersionSnapshot(draft: draft, reason: .manual)
    var firstTargetDraft = draft
    firstTargetDraft.bodyMarkdown = "目标 A"
    var secondTargetDraft = draft
    secondTargetDraft.bodyMarkdown = "目标 B"
    let firstTarget = DraftVersionSnapshot(draft: firstTargetDraft, reason: .automatic)
    let secondTarget = DraftVersionSnapshot(draft: secondTargetDraft, reason: .automatic)
    let firstRequest = DraftVersionComparisonRequest.version(
      sourceVersion: source,
      targetVersion: firstTarget
    )
    let secondRequest = DraftVersionComparisonRequest.version(
      sourceVersion: source,
      targetVersion: secondTarget
    )
    let recorder = DraftVersionComparisonInvocationRecorder()
    let loader = DraftVersionComparisonLoader { previous, current in
      await recorder.compare(previous, current)
    }

    await loader.load(firstRequest)
    await loader.load(secondRequest)
    await loader.load(firstRequest)

    let invocationCount = await recorder.count()
    XCTAssertEqual(invocationCount, 2)
    XCTAssertEqual(
      loader.comparison,
      DraftVersionComparisonService().compare(
        previous: firstRequest.previous,
        current: firstRequest.current
      )
    )
  }

  func testCurrentRequestFreezesLiveBodyAndUsesBufferRevisionInIdentity() {
    let profile = SiteProfile.defaultProfile
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "实时正文",
      bodyMarkdown: "已落盘正文"
    )
    let source = DraftVersionSnapshot(draft: draft, reason: .manual)

    let first = DraftVersionComparisonRequest.current(
      sourceVersion: source,
      targetDraft: draft,
      bodyMarkdown: "尚未落盘的正文",
      bodyRevision: 7
    )
    let second = DraftVersionComparisonRequest.current(
      sourceVersion: source,
      targetDraft: draft,
      bodyMarkdown: "下一次实时正文",
      bodyRevision: 8
    )

    XCTAssertEqual(first.current.bodyMarkdown, "尚未落盘的正文")
    XCTAssertEqual(second.current.bodyMarkdown, "下一次实时正文")
    XCTAssertNotEqual(first.key, second.key)
  }
}
