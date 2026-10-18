import AppKit
import XCTest

@testable import PersonalSitePublisherMac

@MainActor
final class WorkspaceCommandPaletteOutsideClickDismissalTests: XCTestCase {
  private typealias ObservationView = WorkspaceCommandPaletteOutsideClickDismissal.ObservationView

  func testPresentingWindowOutsideClickDismissesOnceAndIsConsumed() throws {
    try withPalette { parent, _, view in
      var dismissals = 0
      view.update(isEnabled: true) { dismissals += 1 }
      let click = try mouseEvent(in: parent)
      XCTAssertNil(view.handleMouseDown(click))
      XCTAssertEqual(dismissals, 1)
      XCTAssertTrue(view.handleMouseDown(click) === click)
      XCTAssertEqual(dismissals, 1)
    }
  }

  func testRightClickOutsideAlsoDismisses() throws {
    try withPalette { parent, _, view in
      var dismissals = 0
      view.update(isEnabled: true) { dismissals += 1 }
      XCTAssertNil(view.handleMouseDown(try mouseEvent(in: parent, type: .rightMouseDown)))
      XCTAssertEqual(dismissals, 1)
    }
  }

  func testPaletteInputAndResultClicksPassThrough() throws {
    try withPalette { _, sheet, view in
      view.update(isEnabled: true) { XCTFail("Internal clicks must retain their existing actions") }
      for point in [NSPoint(x: 50, y: 530), NSPoint(x: 50, y: 200)] {
        let click = try mouseEvent(in: sheet, at: point)
        XCTAssertTrue(view.handleMouseDown(click) === click)
      }
    }
  }

  func testParentEventOverSheetFrameDoesNotDismiss() throws {
    try withPalette { parent, sheet, view in
      view.update(isEnabled: true) {
        XCTFail("A retargeted click inside the sheet must pass through")
      }
      let point = parent.convertPoint(fromScreen: NSPoint(x: sheet.frame.midX, y: sheet.frame.midY))
      let click = try mouseEvent(in: parent, at: point)
      XCTAssertTrue(view.handleMouseDown(click) === click)
    }
  }

  func testOtherWindowClicksDoNotDismiss() throws {
    try withPalette { _, _, view in
      let other = makeWindow()
      defer { other.close() }
      view.update(isEnabled: true) { XCTFail("Another workspace must not dismiss this palette") }
      let click = try mouseEvent(in: other)
      XCTAssertTrue(view.handleMouseDown(click) === click)
    }
  }

  func testNestedSheetAndDisabledStateSuspendDismissal() throws {
    try withPalette { parent, sheet, view in
      var dismissals = 0
      view.update(isEnabled: false) { dismissals += 1 }
      let click = try mouseEvent(in: parent)
      XCTAssertTrue(view.handleMouseDown(click) === click)
      view.update(isEnabled: true) { dismissals += 1 }
      let nested = makeWindow()
      defer { nested.close() }
      sheet.testAttachedSheet = nested
      XCTAssertTrue(view.handleMouseDown(click) === click)
      XCTAssertEqual(dismissals, 0)
      sheet.testAttachedSheet = nil
      XCTAssertNil(view.handleMouseDown(click))
      XCTAssertEqual(dismissals, 1)
    }
  }

  func testDetachDismantleAndReattachmentManageMonitorLifetime() throws {
    try withPalette { parent, sheet, view in
      var dismissals = 0
      view.update(isEnabled: true) { dismissals += 1 }
      let click = try mouseEvent(in: parent)
      XCTAssertTrue(view.isMonitoring)
      view.removeFromSuperview()
      XCTAssertFalse(view.isMonitoring)
      XCTAssertTrue(view.handleMouseDown(click) === click)
      try XCTUnwrap(sheet.contentView).addSubview(view)
      XCTAssertTrue(view.isMonitoring)
      WorkspaceCommandPaletteOutsideClickDismissal.dismantleNSView(view, coordinator: ())
      XCTAssertFalse(view.isMonitoring)
      XCTAssertTrue(view.handleMouseDown(click) === click)
      XCTAssertEqual(dismissals, 0)
    }
  }

  func testEndedSheetAndLatestCallbackAreRespected() throws {
    try withPalette { parent, sheet, view in
      view.update(isEnabled: true) { XCTFail("The old callback must not be retained") }
      var dismissals = 0
      view.update(isEnabled: true) { dismissals += 1 }
      let click = try mouseEvent(in: parent)
      parent.testAttachedSheet = nil
      XCTAssertTrue(view.handleMouseDown(click) === click)
      parent.testAttachedSheet = sheet
      XCTAssertNil(view.handleMouseDown(click))
      XCTAssertEqual(dismissals, 1)
    }
  }

  private func withPalette(
    _ body: (PaletteTestWindow, PaletteTestWindow, ObservationView) throws -> Void
  ) throws {
    let parent = makeWindow()
    let sheet = makeWindow()
    sheet.setFrame(NSRect(x: 300, y: 300, width: 620, height: 560), display: false)
    parent.testAttachedSheet = sheet
    sheet.testSheetParent = parent
    let view = ObservationView()
    try XCTUnwrap(sheet.contentView).addSubview(view)
    defer {
      view.removeFromSuperview()
      parent.close()
      sheet.close()
    }
    try body(parent, sheet, view)
  }

  private func makeWindow() -> PaletteTestWindow {
    _ = NSApplication.shared
    let window = PaletteTestWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1200, height: 900),
      styleMask: [.titled], backing: .buffered, defer: true
    )
    window.isReleasedWhenClosed = false
    return window
  }

  private func mouseEvent(
    in window: NSWindow, at point: NSPoint = NSPoint(x: 20, y: 20),
    type: NSEvent.EventType = .leftMouseDown
  ) throws -> NSEvent {
    // Unshown windows intentionally have no WindowServer event identity.
    // Supply the same public event properties without ordering windows front.
    PaletteTestMouseEvent(window: window, point: point, type: type)
  }
}

@MainActor
private final class PaletteTestWindow: NSWindow {
  weak var testSheetParent: NSWindow?
  weak var testAttachedSheet: NSWindow?
  override var sheetParent: NSWindow? { testSheetParent }
  override var attachedSheet: NSWindow? { testAttachedSheet }
}

private final class PaletteTestMouseEvent: NSEvent {
  private let targetWindow: NSWindow
  private let point: NSPoint
  private let eventType: NSEvent.EventType

  init(window: NSWindow, point: NSPoint, type: NSEvent.EventType) {
    targetWindow = window
    self.point = point
    eventType = type
    super.init()
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not used by this event fixture")
  }

  override var window: NSWindow? { targetWindow }
  override var locationInWindow: NSPoint { point }
  override var type: NSEvent.EventType { eventType }
}
