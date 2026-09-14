import AppKit
import SwiftUI
import XCTest

@testable import PersonalSitePublisherMac
@testable import PublishingAICore

@MainActor
final class SettingsSubsectionAnchorLayoutTests: XCTestCase {
  func testFormAnchorsPreserveLayoutAndScrollToFullWidthHeaders() throws {
    for width: CGFloat in [440, 800] {
      let baseline = render(width: width, placement: .header, includesAnchors: false)
      let anchored = render(width: width, placement: .header)
      assertMatchingContentFrames(baseline.state, anchored.state)
      try assertFullWidthAnchorsAndScroll(anchored)
    }
  }

  func testHeaderlessFormAnchorsPreserveLayoutAndScrollToContent() throws {
    let baseline = render(width: 580, placement: .content, includesAnchors: false)
    let anchored = render(width: 580, placement: .content)
    assertMatchingContentFrames(baseline.state, anchored.state)
    try assertFullWidthAnchorsAndScroll(anchored)
  }

  func testAdvancedSettingsKeepOneAnchorWithAndWithoutTheProxySection() {
    for usesCodex in [false, true] {
      let state = AnchorLayoutState()
      let content = Form {
        AIAdvancedSettingsSection(
          settings: .constant(AIProviderAdvancedSettings()),
          reasoningSupport: .unsupported,
          usesCodexAppServer: usesCodex,
          subsectionAnchor: .aiAdvanced
        )
      }
      .formStyle(.grouped)
      .padding(WorkbenchSpacing.content)
      .coordinateSpace(name: SettingsSubsectionAnchor.coordinateSpaceName)
      .onPreferenceChange(SettingsSubsectionAnchorFramePreferenceKey.self) {
        state.anchorFrames = $0
      }
      let window = makeWindow(content, width: 580)
      settle(window)
      XCTAssertEqual(Set(state.anchorFrames.keys), [.aiAdvanced])
      XCTAssertGreaterThan(state.anchorFrames[.aiAdvanced]?.width ?? 0, 400)
      XCTAssertLessThan(state.anchorFrames[.aiAdvanced]?.minY ?? .infinity, 50)
    }
  }

  private func assertMatchingContentFrames(
    _ baseline: AnchorLayoutState,
    _ anchored: AnchorLayoutState,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertEqual(baseline.contentFrames.count, 4, file: file, line: line)
    XCTAssertEqual(anchored.contentFrames, baseline.contentFrames, file: file, line: line)
  }

  private func assertFullWidthAnchorsAndScroll(
    _ rendered: (window: NSWindow, state: AnchorLayoutState),
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws {
    let state = rendered.state
    XCTAssertEqual(state.anchorFrames.count, 4, file: file, line: line)
    for subsection in SettingsSubsection.sections(for: .appearance) {
      let anchor = try XCTUnwrap(state.anchorFrames[subsection], file: file, line: line)
      let content = try XCTUnwrap(state.contentFrames[subsection], file: file, line: line)
      XCTAssertEqual(anchor.minY, content.minY, accuracy: 1, file: file, line: line)
      XCTAssertEqual(anchor.minX, content.minX, accuracy: 1, file: file, line: line)
      XCTAssertEqual(anchor.width, content.width, accuracy: 1, file: file, line: line)
      XCTAssertGreaterThan(anchor.width, 300, file: file, line: line)
      XCTAssertEqual(anchor.height, 0, file: file, line: line)
    }
    let originalTarget = try XCTUnwrap(state.anchorFrames[.appearanceLanguage]).minY
    XCTAssertGreaterThan(originalTarget, 300, file: file, line: line)
    state.target = .appearanceLanguage
    settle(rendered.window)
    let scrolledTarget = try XCTUnwrap(state.anchorFrames[.appearanceLanguage])
    XCTAssertEqual(
      scrolledTarget.minY, WorkbenchSpacing.content, accuracy: 1, file: file, line: line
    )
    XCTAssertLessThan(
      try XCTUnwrap(state.anchorFrames[.appearanceBehavior]).minY, 0,
      file: file, line: line
    )
    XCTAssertEqual(
      SettingsSubsectionVisibilityPolicy.visibleSubsection(
        in: .appearance, anchorFrames: state.anchorFrames
      ),
      .appearanceLanguage, file: file, line: line
    )
    let highlight = SettingsSearchHighlight(subsection: .appearanceLanguage)
    let frame = highlight.visibleFrame(
      anchorFrames: state.anchorFrames,
      viewport: CGRect(x: 0, y: 0, width: rendered.window.frame.width, height: 300)
    )
    XCTAssertGreaterThan(try XCTUnwrap(frame).width, 300, file: file, line: line)
  }

  private func render(
    width: CGFloat,
    placement: AnchorLayoutFixture.Placement,
    includesAnchors: Bool = true
  ) -> (window: NSWindow, state: AnchorLayoutState) {
    let state = AnchorLayoutState()
    let window = makeWindow(
      AnchorLayoutFixture(
        state: state, placement: placement, includesAnchors: includesAnchors
      ), width: width
    )
    settle(window)
    return (window, state)
  }

  private func makeWindow(_ content: some View, width: CGFloat) -> NSWindow {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: width, height: 300),
      styleMask: [.borderless], backing: .buffered, defer: false
    )
    window.appearance = NSAppearance(named: .aqua)
    window.contentView = NSHostingView(rootView: content.frame(width: width, height: 300))
    window.layoutIfNeeded()
    return window
  }

  private func settle(_ window: NSWindow) {
    for _ in 0..<5 {
      RunLoop.main.run(until: Date().addingTimeInterval(0.05))
      window.displayIfNeeded()
    }
  }
}

@MainActor
private final class AnchorLayoutState: ObservableObject {
  @Published var target: SettingsSubsection?
  var anchorFrames: [SettingsSubsection: CGRect] = [:]
  var contentFrames: [SettingsSubsection: CGRect] = [:]
}

private struct AnchorContentFrameKey: PreferenceKey {
  static let defaultValue: [SettingsSubsection: CGRect] = [:]
  static func reduce(
    value: inout [SettingsSubsection: CGRect],
    nextValue: () -> [SettingsSubsection: CGRect]
  ) {
    value.merge(nextValue(), uniquingKeysWith: { _, new in new })
  }
}

private struct AnchorLayoutFixture: View {
  enum Placement { case header, content }
  @ObservedObject var state: AnchorLayoutState
  let placement: Placement
  let includesAnchors: Bool

  var body: some View {
    ScrollViewReader { proxy in
      Form {
        ForEach(SettingsSubsection.sections(for: .appearance)) { subsection in
          if placement == .header {
            Section {
              rows
            } header: {
              measuredContent(subsection)
            }
          } else {
            Section {
              measuredContent(subsection)
              rows
            }
          }
        }
      }
      .formStyle(.grouped)
      .padding(WorkbenchSpacing.content)
      .coordinateSpace(name: SettingsSubsectionAnchor.coordinateSpaceName)
      .onPreferenceChange(SettingsSubsectionAnchorFramePreferenceKey.self) {
        state.anchorFrames = $0
      }
      .onPreferenceChange(AnchorContentFrameKey.self) { state.contentFrames = $0 }
      .onChange(of: state.target) { _, target in
        if let target { proxy.scrollTo(target.id, anchor: .top) }
      }
    }
  }

  private var rows: some View {
    ForEach(0..<4) { index in
      Text(verbatim: "Setting \(index)")
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }
  }

  private func measuredContent(_ subsection: SettingsSubsection) -> some View {
    Text(verbatim: subsection.rawValue)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background {
        GeometryReader { proxy in
          Color.clear.preference(
            key: AnchorContentFrameKey.self,
            value: [
              subsection: proxy.frame(in: .named(SettingsSubsectionAnchor.coordinateSpaceName))
            ]
          )
        }
      }
      .settingsSubsectionAnchor(includesAnchors ? subsection : nil)
  }
}
