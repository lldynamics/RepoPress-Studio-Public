import AppKit
import XCTest

@testable import PersonalSitePublisherMac

final class MarkdownComposerPerformanceTests: XCTestCase {
  func testScrollProgressCoalescerDeliversOnlyLatestProgressPerIdleBurst() {
    var coalescer = MarkdownScrollProgressCoalescer()

    XCTAssertTrue(coalescer.receive(0.10))
    XCTAssertTrue(coalescer.receive(0.35))
    XCTAssertTrue(coalescer.receive(0.80))
    XCTAssertEqual(coalescer.deliverLatest(), 0.80)
    XCTAssertNil(coalescer.deliverLatest())

    XCTAssertFalse(coalescer.receive(0.8005))
    XCTAssertNil(coalescer.deliverLatest())
    XCTAssertTrue(coalescer.receive(0.82))
    XCTAssertEqual(coalescer.deliverLatest(), 0.82)
  }

  func testScrollProgressCoalescerClampsInvalidValuesAndPreservesLastValue() {
    var coalescer = MarkdownScrollProgressCoalescer()

    XCTAssertTrue(coalescer.receive(.infinity))
    XCTAssertEqual(coalescer.deliverLatest(), 0)
    XCTAssertFalse(coalescer.receive(-1))
    XCTAssertNil(coalescer.deliverLatest())
    XCTAssertTrue(coalescer.receive(2))
    XCTAssertEqual(coalescer.deliverLatest(), 1)
  }
}
