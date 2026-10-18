import AppKit
import Observation
import SwiftUI
import XCTest

@testable import PersonalSitePublisherMac

@MainActor
final class WorkbenchTypographyTests: XCTestCase {
  func testReadingFontTokensObservesScaleChanges() {
    let original = WorkbenchTextScale.current
    WorkbenchTextScale.shared.apply(.standard)
    defer { restoreScale(original) }
    let changed = expectation(description: "Font readers observe the preference change")
    withObservationTracking {
      _ = Font.workbenchBody
      _ = Font.workbenchPageTitle
    } onChange: {
      changed.fulfill()
    }
    WorkbenchTextScale.shared.apply(.largest)
    XCTAssertEqual(WorkbenchTextScale.current, 1.5)
    wait(for: [changed], timeout: 1)
  }

  func testApplyingSamePreferenceDoesNotInvalidateReaders() {
    let state = WorkbenchTextScaleState(preference: .extraLarge)
    let changed = expectation(description: "Identical settings do not invalidate views")
    changed.isInverted = true
    withObservationTracking {
      XCTAssertEqual(state.scale, 1.3)
    } onChange: {
      changed.fulfill()
    }
    state.apply(.extraLarge)
    wait(for: [changed], timeout: 0.05)
  }

  func testMountedFontReadersResizeWithoutRecreatingLocalState() {
    let original = WorkbenchTextScale.current
    WorkbenchTextScale.shared.apply(.standard)
    defer { restoreScale(original) }
    let probe = TypographyRenderProbe()
    let host = NSHostingView(rootView: TypographyFixture(probe: probe))
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 500, height: 120),
      styleMask: [.borderless], backing: .buffered, defer: false
    )
    window.contentView = host
    settle(window)
    let firstIdentity = probe.identities.last
    let standardSize = host.fittingSize
    let initialRenderCount = probe.identities.count

    WorkbenchTextScale.shared.apply(.largest)
    settle(window)

    XCTAssertGreaterThan(probe.identities.count, initialRenderCount)
    XCTAssertEqual(Set(probe.identities).count, 1)
    XCTAssertEqual(probe.identities.last, firstIdentity)
    XCTAssertGreaterThan(host.fittingSize.height, standardSize.height)
    XCTAssertGreaterThan(host.fittingSize.width, standardSize.width)
  }

  func testScaledMenuPickerConfiguresNativeFontAndAccessibilityAtLargestScale() {
    var selection = "standard"
    let picker = WorkbenchScaledMenuPicker(
      title: "界面字号",
      selection: Binding(get: { selection }, set: { selection = $0 }),
      options: [
        .init(value: "standard", title: "100%"),
        .init(value: "largest", title: "150%"),
      ],
      accessibilityIdentifier: "settings-interface-text-scale-picker"
    )
    let control = NSPopUpButton(frame: .zero, pullsDown: false)

    picker.configure(control, scale: 1.5)

    XCTAssertEqual(control.font?.pointSize, 20)
    XCTAssertEqual(control.menu?.font?.pointSize, 20)
    XCTAssertEqual(control.accessibilityLabel(), "界面字号")
    XCTAssertEqual(
      control.accessibilityIdentifier(),
      "settings-interface-text-scale-picker"
    )
    XCTAssertEqual(control.selectedItem?.representedObject as? String, selection)
    XCTAssertEqual(control.selectedItem?.title, "100%")
  }

  func testScaledMenuPickerUsesStandardFontAndCoordinatorWritesSelection() {
    var selection = "standard"
    let picker = WorkbenchScaledMenuPicker(
      title: "界面字号",
      selection: Binding(get: { selection }, set: { selection = $0 }),
      options: [
        .init(value: "standard", title: "100%"),
        .init(value: "largest", title: "150%"),
      ],
      accessibilityIdentifier: "settings-interface-text-scale-picker"
    )
    let control = NSPopUpButton(frame: .zero, pullsDown: false)
    picker.configure(control, scale: 1)
    let coordinator = picker.makeCoordinator()

    XCTAssertEqual(control.font?.pointSize, 13)
    XCTAssertEqual(control.menu?.font?.pointSize, 13)
    control.selectItem(at: 1)
    coordinator.selectOption(control)

    XCTAssertEqual(selection, "largest")
    XCTAssertEqual(control.selectedItem?.representedObject as? String, selection)
    XCTAssertEqual(control.selectedItem?.title, "150%")
  }

  private func settle(_ window: NSWindow) {
    for _ in 0..<5 {
      RunLoop.main.run(until: Date().addingTimeInterval(0.02))
      window.layoutIfNeeded()
    }
  }

  private func restoreScale(_ value: CGFloat) {
    WorkbenchTextScale.shared.apply(
      WorkbenchTextScalePreference.allCases.first { $0.scale == value } ?? .standard
    )
  }
}

@MainActor
private final class TypographyRenderProbe {
  var identities: [UUID] = []
}

private struct TypographyFixture: View {
  let probe: TypographyRenderProbe
  @State private var identity = UUID()

  var body: some View {
    probe.identities.append(identity)
    return VStack {
      Text("工作台标题 Typography").font(.workbenchPageTitle)
      Text("状态和正文界面文字").font(.workbenchBody)
    }
    .fixedSize()
  }
}
