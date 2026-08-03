import Foundation
import XCTest

@testable import PublishingWorkbenchCore

final class AIStructuredEditingServiceTests: XCTestCase {
  func testParsesBareAndFencedStrictJSONWithUTF16Ranges() throws {
    let source = "标题😀有有重复。"
    let targetRange = (source as NSString).range(of: "有有")
    let json = responseJSON(
      changes: [
        try proposalJSON(
          id: "C1",
          range: targetRange,
          original: "有有",
          replacement: "有",
          reason: "删除重复用字",
          category: "grammar",
          confidence: 0.99
        )
      ]
    )

    let bare = try AIStructuredEditParser.parse(json, sourceBody: source)
    let fenced = try AIStructuredEditParser.parse(
      "```json\n\(json)\n```",
      sourceBody: source
    )

    XCTAssertEqual(bare, fenced)
    XCTAssertEqual(bare.changes.first?.range.location, targetRange.location)
    XCTAssertEqual(bare.changes.first?.range.length, targetRange.length)
  }

  func testParserRejectsProseUnknownKeysAndMarkdownWithoutJSONLanguage() throws {
    let source = "错字"
    let valid = responseJSON(
      changes: [
        try proposalJSON(
          id: "C1",
          range: NSRange(location: 0, length: 1),
          original: "错",
          replacement: "措",
          reason: "测试",
          category: "spelling",
          confidence: 0.8
        )
      ]
    )
    let unknownKey = valid.replacingOccurrences(
      of: #""confidence":0.8"#,
      with: #""confidence":0.8,"comment":"extra""#
    )

    XCTAssertThrowsError(
      try AIStructuredEditParser.parse("结果如下：\n\(valid)", sourceBody: source)
    ) { error in
      XCTAssertEqual(
        error as? AIStructuredEditValidationError,
        .responseIsNotStrictJSON
      )
    }
    XCTAssertThrowsError(
      try AIStructuredEditParser.parse("```\n\(valid)\n```", sourceBody: source)
    ) { error in
      XCTAssertEqual(
        error as? AIStructuredEditValidationError,
        .responseIsNotStrictJSON
      )
    }
    XCTAssertThrowsError(
      try AIStructuredEditParser.parse(unknownKey, sourceBody: source)
    ) { error in
      XCTAssertEqual(
        error as? AIStructuredEditValidationError,
        .invalidJSONContract
      )
    }
  }

  func testParserRejectsStaleOriginalAndOverlappingRanges() throws {
    let stale = responseJSON(
      changes: [
        try proposalJSON(
          id: "C1",
          range: NSRange(location: 0, length: 2),
          original: "旧文",
          replacement: "新文",
          reason: "更新",
          category: "clarity",
          confidence: 0.7
        )
      ]
    )
    XCTAssertThrowsError(
      try AIStructuredEditParser.parse(stale, sourceBody: "正文")
    ) { error in
      XCTAssertEqual(
        error as? AIStructuredEditValidationError,
        .originalTextChanged("C1")
      )
    }

    let overlapping = responseJSON(
      changes: [
        try proposalJSON(
          id: "C1",
          range: NSRange(location: 0, length: 3),
          original: "abc",
          replacement: "ABC",
          reason: "第一项",
          category: "style",
          confidence: 0.9
        ),
        try proposalJSON(
          id: "C2",
          range: NSRange(location: 2, length: 2),
          original: "cd",
          replacement: "CD",
          reason: "第二项",
          category: "style",
          confidence: 0.9
        ),
      ]
    )
    XCTAssertThrowsError(
      try AIStructuredEditParser.parse(overlapping, sourceBody: "abcdef")
    ) { error in
      XCTAssertEqual(
        error as? AIStructuredEditValidationError,
        .overlappingChanges("C1", "C2")
      )
    }
  }

  func testAcceptRejectAndApplyAllProduceStableFinalBodyAndDiffRanges() throws {
    let source = "bad cat and bad dog"
    let firstRange = (source as NSString).range(of: "bad")
    let secondRange = (source as NSString).range(
      of: "bad",
      options: [],
      range: NSRange(
        location: firstRange.location + firstRange.length,
        length: (source as NSString).length - firstRange.location - firstRange.length
      )
    )
    let document = try AIStructuredEditParser.parse(
      responseJSON(
        changes: [
          try proposalJSON(
            id: "C2",
            range: secondRange,
            original: "bad",
            replacement: "great",
            reason: "增强语气",
            category: "style",
            confidence: 0.75
          ),
          try proposalJSON(
            id: "C1",
            range: firstRange,
            original: "bad",
            replacement: "good",
            reason: "改善表达",
            category: "clarity",
            confidence: 0.95
          ),
        ]
      ),
      sourceBody: source
    )

    var review = AIStructuredEditReviewService.initialReview(for: document)
    review = try AIStructuredEditReviewService.accepting("C1", in: review)
    review = try AIStructuredEditReviewService.rejecting("C2", in: review)
    let partial = try AIStructuredEditReviewService.apply(review, to: source)

    XCTAssertEqual(partial.finalBody, "good cat and bad dog")
    XCTAssertEqual(partial.acceptedIDs, ["C1"])
    XCTAssertEqual(partial.rejectedIDs, ["C2"])
    XCTAssertEqual(partial.hunks.map(\.id), ["C1", "C2"])
    XCTAssertEqual(partial.hunks[0].resultingRange?.location, 0)
    XCTAssertNil(partial.hunks[1].resultingRange)

    let applyAll = try AIStructuredEditReviewService.apply(
      AIStructuredEditReviewService.acceptingAll(in: review),
      to: source
    )
    XCTAssertEqual(applyAll.finalBody, "good cat and great dog")
    XCTAssertEqual(applyAll.acceptedIDs, ["C1", "C2"])
    XCTAssertEqual(
      applyAll.hunks[1].resultingRange?.location,
      secondRange.location + 1
    )
    XCTAssertEqual(applyAll.hunks[1].resultingRange?.length, 5)

    let rejectAll = try AIStructuredEditReviewService.apply(
      AIStructuredEditReviewService.rejectingAll(in: review),
      to: source
    )
    XCTAssertEqual(rejectAll.finalBody, source)
    XCTAssertFalse(rejectAll.hasAppliedChanges)
  }

  func testApplyRevalidatesSourceAndUnknownDecisionIsRejected() throws {
    let source = "原始正文"
    let range = (source as NSString).range(of: "原始")
    let document = try AIStructuredEditParser.parse(
      responseJSON(
        changes: [
          try proposalJSON(
            id: "C1",
            range: range,
            original: "原始",
            replacement: "更新",
            reason: "改善表达",
            category: "clarity",
            confidence: 0.8
          )
        ]
      ),
      sourceBody: source
    )
    let review = AIStructuredEditReviewService.initialReview(for: document)

    XCTAssertThrowsError(
      try AIStructuredEditReviewService.accepting("missing", in: review)
    ) { error in
      XCTAssertEqual(
        error as? AIStructuredEditReviewError,
        .unknownProposal("missing")
      )
    }
    XCTAssertThrowsError(
      try AIStructuredEditReviewService.apply(review, to: "正文已变化")
    ) { error in
      XCTAssertEqual(
        error as? AIStructuredEditValidationError,
        .originalTextChanged("C1")
      )
    }
  }

  private func responseJSON(changes: [String]) -> String {
    #"{"schemaVersion":1,"changes":[\#(changes.joined(separator: ","))]}"#
  }

  private func proposalJSON(
    id: String,
    range: NSRange,
    original: String,
    replacement: String,
    reason: String,
    category: String,
    confidence: Double
  ) throws -> String {
    let object: [String: Any] = [
      "id": id,
      "range": [
        "location": range.location,
        "length": range.length,
      ],
      "originalText": original,
      "replacementText": replacement,
      "reason": reason,
      "category": category,
      "confidence": confidence,
    ]
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return String(decoding: data, as: UTF8.self)
  }
}
