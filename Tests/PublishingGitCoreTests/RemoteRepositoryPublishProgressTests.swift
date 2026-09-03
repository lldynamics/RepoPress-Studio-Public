import Foundation
import PublishingGitCore
import XCTest

final class RemoteRepositoryPublishProgressTests: XCTestCase {
  func testByteProgressDescriptionIncludesReadableBytesAndPercentage() throws {
    let progress = RemoteRepositoryPublishProgress(
      stage: .uploadingFiles,
      progress: 0.655,
      message: "推送图片资产",
      detail: "第 2/4 个文件",
      completedByteCount: 12_300_000,
      totalByteCount: 18_900_000
    )

    XCTAssertEqual(
      try XCTUnwrap(progress.byteProgress),
      12_300_000.0 / 18_900_000.0,
      accuracy: 0.000_001
    )
    XCTAssertEqual(progress.byteProgressDescription, "12.3 MB / 18.9 MB (65%)")
    XCTAssertEqual(
      progress.statusDescription,
      "推送图片资产 · 第 2/4 个文件 · 已上传 12.3 MB / 18.9 MB (65%)"
    )
  }

  func testMissingByteTotalsKeepIndeterminateProgressAndDecodeLegacyPayload() throws {
    let progress = RemoteRepositoryPublishProgress(
      stage: .uploadingFiles,
      progress: nil,
      message: "提交文件",
      detail: "第 1/1 个文件"
    )
    XCTAssertNil(progress.byteProgress)
    XCTAssertNil(progress.byteProgressDescription)

    let data = Data(
      #"{"stage":"uploadingFiles","progress":0.4,"message":"提交文件","detail":"第 1/1 个文件"}"#.utf8
    )
    let decoded = try JSONDecoder().decode(RemoteRepositoryPublishProgress.self, from: data)
    XCTAssertNil(decoded.completedByteCount)
    XCTAssertNil(decoded.totalByteCount)
    XCTAssertNil(decoded.byteProgressDescription)
  }
}
