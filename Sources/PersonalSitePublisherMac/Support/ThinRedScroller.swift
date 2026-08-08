import AppKit
import Foundation
import SwiftUI

@MainActor
public final class ThinRedScroller: NSScroller {
  /// Visible knob width. The NSScroller view keeps its native width so the
  /// system hit area remains available for pointer and accessibility input.
  public static let thinWidth: CGFloat = 2.5

  private var settingsKnobLayer: CALayer?

  private static func knobColor(for appearance: NSAppearance) -> NSColor {
    let appearanceName = appearance.name.rawValue.lowercased()
    let isDark = appearanceName.contains("dark")
    let isHighContrast = appearanceName.contains("highcontrast")

    // Keep the semantic color red in every appearance. High-contrast
    // appearances use full opacity so the narrow track remains discoverable.
    let baseColor = NSColor.systemRed
    let alpha: CGFloat = isHighContrast ? 1.0 : (isDark ? 0.92 : 0.78)
    return baseColor.withAlphaComponent(alpha)
  }

  override public class var isCompatibleWithOverlayScrollers: Bool {
    true
  }

  override public func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {
    // Keep slot completely transparent for a clean borderless look
  }

  override public func draw(_ dirtyRect: NSRect) {
    // Overlay scrollers do not reliably dispatch drawKnob() on every macOS
    // release. Draw through the native NSScroller view itself so the system
    // keeps ownership of hit testing, dragging, keyboard scrolling, and
    // auto-hide while the track remains transparent.
    drawKnob()
  }

  override public var doubleValue: Double {
    didSet {
      updateSettingsKnobLayer()
    }
  }

  override public var knobProportion: CGFloat {
    didSet {
      updateSettingsKnobLayer()
    }
  }

  override public func layout() {
    super.layout()
    updateSettingsKnobLayer()
  }

  /// Enables the settings-only layer fallback for overlay scrollers whose
  /// AppKit implementation bypasses NSScroller.drawKnob(). The layer remains
  /// inside this native NSScroller, so the system still owns hit testing,
  /// dragging, keyboard scrolling, accessibility and auto-hide.
  func enableSettingsKnobLayer() {
    if settingsKnobLayer == nil {
      wantsLayer = true
      let layer = CALayer()
      layer.zPosition = 1
      layer.masksToBounds = true
      settingsKnobLayer = layer
      self.layer?.addSublayer(layer)
    }
    updateSettingsKnobLayer()
  }

  private func updateSettingsKnobLayer() {
    guard let layer = settingsKnobLayer else { return }

    let rect = self.rect(for: .knob)
    guard !rect.isEmpty,
          bounds.width > 0,
          bounds.height > 0,
          isEnabled,
          knobProportion > 0 else {
      layer.isHidden = true
      return
    }

    let knobRect: NSRect
    let isVertical = bounds.width < bounds.height
    if isVertical {
      knobRect = NSRect(
        x: bounds.maxX - Self.thinWidth,
        y: rect.minY,
        width: Self.thinWidth,
        height: rect.height
      )
    } else {
      knobRect = NSRect(
        x: rect.minX,
        y: bounds.maxY - Self.thinWidth,
        width: rect.width,
        height: Self.thinWidth
      )
    }

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    layer.frame = knobRect
    layer.backgroundColor = Self.knobColor(for: effectiveAppearance).cgColor
    layer.cornerRadius = Self.thinWidth / 2.0
    layer.isHidden = false
    CATransaction.commit()
  }

  override public func drawKnob() {
    let rect = self.rect(for: .knob)
    guard !rect.isEmpty else { return }

    let knobRect: NSRect
    let isVertical = bounds.width < bounds.height
    if isVertical {
      let x = bounds.maxX - Self.thinWidth
      knobRect = NSRect(x: x, y: rect.minY, width: Self.thinWidth, height: rect.height)
    } else {
      let y = bounds.maxY - Self.thinWidth
      knobRect = NSRect(x: rect.minX, y: y, width: rect.width, height: Self.thinWidth)
    }

    let path = NSBezierPath(
      roundedRect: knobRect,
      xRadius: Self.thinWidth / 2.0,
      yRadius: Self.thinWidth / 2.0
    )
    Self.knobColor(for: effectiveAppearance).setFill()
    path.fill()
  }
}

/// Settings-only scroller policy. The Settings window keeps the native
/// NSScroller hit area and interaction model, while drawing only a thin
/// vertical red knob and suppressing horizontal indicators that would signal
/// an accidental horizontal layout overflow.
@MainActor
enum SettingsScrollViewStyling {
  static func install(on scrollView: NSScrollView) {
    if scrollView.hasVerticalScroller,
       !(scrollView.verticalScroller is ThinRedScroller) {
      let scroller = ThinRedScroller()
      scrollView.verticalScroller = scroller
    }

    // NSScrollView can apply its own legacy style after a custom scroller is
    // assigned, especially for SwiftUI's delayed Form/HostingScrollView
    // construction. Reassert the page-local overlay style after replacement
    // and refresh the native knob geometry from the current clip view.
    scrollView.scrollerStyle = .overlay
    scrollView.verticalScroller?.scrollerStyle = .overlay
    scrollView.reflectScrolledClipView(scrollView.contentView)
    (scrollView.verticalScroller as? ThinRedScroller)?.enableSettingsKnobLayer()

    if scrollView.hasHorizontalScroller {
      scrollView.hasHorizontalScroller = false
      scrollView.horizontalScrollElasticity = .none
    }
  }

  static func install(in view: NSView) {
    if let scrollView = view as? NSScrollView {
      install(on: scrollView)
    }
    for subview in view.subviews {
      install(in: subview)
    }
  }

  static func belongs(candidate: NSWindow, to root: NSWindow) -> Bool {
    var current: NSWindow? = candidate
    while let window = current {
      if window === root { return true }
      current = window.sheetParent
    }
    return false
  }

}

/// Applies the custom scroller only to the nearest AppKit scroll view.
///
/// This is deliberately opt-in. The previous implementation swizzled
/// `NSScrollView.tile`, which forced every scroll view in the application to
/// allocate and draw a custom knob, including system and settings surfaces.
public struct ThinRedScrollerModifier: ViewModifier {
  public func body(content: Content) -> some View {
    content.background(ThinRedScrollerConfigurator())
  }
}

public extension View {
  func thinRedScroller() -> some View {
    modifier(ThinRedScrollerModifier())
  }
}

/// Applies the custom scroller to every AppKit scroll view in the window.
///
/// This is installed at scene roots so SwiftUI-created `ScrollView`, `List`,
/// `Table`, and AppKit-backed editor surfaces share the same visual treatment.
private enum ThinRedScrollerInstallationScope {
  case window
  case settings
}

public struct ThinRedScrollbarsModifier: ViewModifier {
  private let scope: ThinRedScrollerInstallationScope

  fileprivate init(scope: ThinRedScrollerInstallationScope = .window) {
    self.scope = scope
  }

  public func body(content: Content) -> some View {
    switch scope {
    case .window:
      content.background(ThinRedScrollbarsConfigurator(scope: scope))
    case .settings:
      content.overlay(alignment: .topLeading) {
        ThinRedScrollbarsConfigurator(scope: scope)
          .frame(width: 1, height: 1)
          .allowsHitTesting(false)
      }
    }
  }
}

public extension View {
  func thinRedScrollbars() -> some View {
    modifier(ThinRedScrollbarsModifier())
  }

  /// Applies the red scroller only to a Settings scene window and its sheets.
  func settingsThinRedScrollbars() -> some View {
    modifier(ThinRedScrollbarsModifier(scope: .settings))
  }

  /// Installs the Settings scroller after this page's native scroll view has
  /// been created. This is intentionally page-local so delayed SwiftUI Form
  /// construction cannot leave a system scroller unstyled.
  func settingsThinRedScroller() -> some View {
    overlay(alignment: .topLeading) {
      SettingsThinRedScrollerConfigurator()
        .frame(width: 1, height: 1)
        .allowsHitTesting(false)
    }
  }
}

private struct SettingsThinRedScrollerConfigurator: NSViewRepresentable {
  func makeNSView(context: Context) -> SettingsThinRedScrollerConfiguratorView {
    SettingsThinRedScrollerConfiguratorView()
  }

  func updateNSView(
    _ nsView: SettingsThinRedScrollerConfiguratorView,
    context: Context
  ) {
    nsView.scheduleConfiguration()
  }
}

private final class SettingsThinRedScrollerConfiguratorView: NSView {
  private var configurationScheduled = false
  private var retryGeneration = 0

  override func viewDidMoveToSuperview() {
    super.viewDidMoveToSuperview()
    scheduleConfiguration()
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    scheduleConfiguration()
  }

  override func layout() {
    super.layout()
    scheduleConfiguration()
  }

  func scheduleConfiguration() {
    guard !configurationScheduled else { return }
    configurationScheduled = true
    retryGeneration += 1
    let generation = retryGeneration
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      configurationScheduled = false
      configureWindow()
      scheduleRetries(generation: generation)
    }
  }

  private func configureWindow() {
    guard let window, let contentView = window.contentView else { return }
    if let scrollView = nearestScrollView {
      SettingsScrollViewStyling.install(on: scrollView)
    } else {
      // Settings/Form page content is sometimes hosted as a sibling of the
      // native HostingScrollView. Scan this Settings window directly so a
      // page switch cannot leave a newly rebuilt scroll view unstyled.
      SettingsScrollViewStyling.install(in: contentView)
    }
  }

  private func scheduleRetries(generation: Int) {
    let delays: [TimeInterval] = [0.05, 0.15, 0.35, 0.65, 1.0]
    for delay in delays {
      DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
        guard let self, self.retryGeneration == generation else { return }
        self.configureWindow()
      }
    }
  }

  private var nearestScrollView: NSScrollView? {
    var ancestor = superview
    while let view = ancestor {
      if let scrollView = view as? NSScrollView { return scrollView }
      ancestor = view.superview
    }
    return nil
  }
}

private extension ThinRedScroller {
  static func install(on scrollView: NSScrollView) {
    if scrollView.hasVerticalScroller,
       !(scrollView.verticalScroller is ThinRedScroller) {
      let scroller = ThinRedScroller()
      scroller.scrollerStyle = .overlay
      scrollView.verticalScroller = scroller
    }
    if scrollView.hasHorizontalScroller,
       !(scrollView.horizontalScroller is ThinRedScroller) {
      let scroller = ThinRedScroller()
      scroller.scrollerStyle = .overlay
      scrollView.horizontalScroller = scroller
    }
  }

  static func install(in view: NSView) {
    if let scrollView = view as? NSScrollView {
      install(on: scrollView)
    }
    for subview in view.subviews {
      install(in: subview)
    }
  }
}

private struct ThinRedScrollerConfigurator: NSViewRepresentable {
  func makeNSView(context: Context) -> ThinRedScrollerConfiguratorView {
    ThinRedScrollerConfiguratorView()
  }

  func updateNSView(_ nsView: ThinRedScrollerConfiguratorView, context: Context) {
    nsView.scheduleConfiguration()
  }
}

private final class ThinRedScrollerConfiguratorView: NSView {
  private var configurationScheduled = false

  override func viewDidMoveToSuperview() {
    super.viewDidMoveToSuperview()
    scheduleConfiguration()
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    scheduleConfiguration()
  }

  func scheduleConfiguration() {
    guard !configurationScheduled else { return }
    configurationScheduled = true
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      configurationScheduled = false
      configureNearestScrollView()
    }
  }

  private func configureNearestScrollView() {
    guard let scrollView = nearestScrollView else { return }
    ThinRedScroller.install(on: scrollView)
  }

  private var nearestScrollView: NSScrollView? {
    var ancestor = superview
    while let view = ancestor {
      if let scrollView = view as? NSScrollView { return scrollView }
      ancestor = view.superview
    }
    return nil
  }
}

private struct ThinRedScrollbarsConfigurator: NSViewRepresentable {
  let scope: ThinRedScrollerInstallationScope

  func makeNSView(context: Context) -> ThinRedScrollbarsConfiguratorView {
    ThinRedScrollbarsConfiguratorView(scope: scope)
  }

  func updateNSView(_ nsView: ThinRedScrollbarsConfiguratorView, context: Context) {
    nsView.scheduleConfiguration()
  }
}

private final class ThinRedScrollbarsConfiguratorView: NSView {
  private let scope: ThinRedScrollerInstallationScope
  private var configurationScheduled = false
  private var pendingWindowIDs = Set<ObjectIdentifier>()
  private var pendingWindows: [NSWindow] = []
  private var windowObservers: [NSObjectProtocol] = []
  private var settingsRetryGeneration = 0

  init(scope: ThinRedScrollerInstallationScope) {
    self.scope = scope
    super.init(frame: .zero)
  }

  required init?(coder: NSCoder) {
    scope = .window
    super.init(coder: coder)
  }

  override func viewDidMoveToSuperview() {
    super.viewDidMoveToSuperview()
    scheduleConfiguration()
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window == nil {
      removeWindowObservers()
    } else {
      installWindowObserversIfNeeded()
    }
    scheduleConfiguration()
  }

  func scheduleConfiguration(for targetWindow: NSWindow? = nil) {
    guard let targetWindow = targetWindow ?? window,
          acceptsTargetWindow(targetWindow) else {
      return
    }

    let identifier = ObjectIdentifier(targetWindow)
    if pendingWindowIDs.insert(identifier).inserted {
      pendingWindows.append(targetWindow)
    }

    guard !configurationScheduled else { return }
    configurationScheduled = true
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      configurationScheduled = false
      let windows = pendingWindows
      pendingWindows.removeAll(keepingCapacity: true)
      pendingWindowIDs.removeAll(keepingCapacity: true)
      configure(windows)
      scheduleSettingsRetriesIfNeeded()
    }
  }

  private func configure(_ windows: [NSWindow]) {
    for targetWindow in windows {
      guard let contentView = targetWindow.contentView else { continue }
      switch scope {
      case .window:
        ThinRedScroller.install(in: contentView)
      case .settings:
        SettingsScrollViewStyling.install(in: contentView)
      }
    }
  }

  private func scheduleSettingsRetriesIfNeeded() {
    guard scope == .settings, let rootWindow = window else { return }

    settingsRetryGeneration += 1
    let generation = settingsRetryGeneration
    // SwiftUI Form/Settings content can replace its native scroll view a few
    // run-loop turns after the selection changes. Keep the retry window short
    // and local to this Settings root plus any sheet it owns.
    let delays: [TimeInterval] = [0.05, 0.15, 0.35, 0.65, 1.0]
    for delay in delays {
      DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak rootWindow] in
        guard let self,
              self.settingsRetryGeneration == generation,
              let rootWindow else { return }
        let settingsWindows = NSApp.windows.filter {
          SettingsScrollViewStyling.belongs(candidate: $0, to: rootWindow)
        }
        self.configure(settingsWindows)
      }
    }
  }

  private func acceptsTargetWindow(_ targetWindow: NSWindow) -> Bool {
    guard let rootWindow = window else { return false }
    switch scope {
    case .window:
      return targetWindow === rootWindow
    case .settings:
      return SettingsScrollViewStyling.belongs(candidate: targetWindow, to: rootWindow)
    }
  }

  private func installWindowObserversIfNeeded() {
    guard windowObservers.isEmpty else { return }

    let center = NotificationCenter.default
    let names: [Notification.Name] = [
      NSWindow.didBecomeKeyNotification,
      NSWindow.didBecomeMainNotification,
    ]
    windowObservers = names.map { name in
      center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
        guard let targetWindow = notification.object as? NSWindow else { return }
        Task { @MainActor [weak self] in
          guard let self, self.acceptsTargetWindow(targetWindow) else { return }
          self.scheduleConfiguration(for: targetWindow)
        }
      }
    }
  }

  private func removeWindowObservers() {
    let center = NotificationCenter.default
    for observer in windowObservers {
      center.removeObserver(observer)
    }
    windowObservers.removeAll()
  }

}
