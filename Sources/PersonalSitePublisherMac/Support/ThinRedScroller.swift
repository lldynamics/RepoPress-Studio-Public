import AppKit
import Foundation
import SwiftUI

@MainActor
public final class ThinRedScroller: NSScroller {
  public static let thinWidth: CGFloat = 3.5
  private static let knobColor = NSColor.systemRed.withAlphaComponent(0.85)

  override public class var isCompatibleWithOverlayScrollers: Bool {
    true
  }

  override public class func scrollerWidth(
    for controlSize: NSControl.ControlSize,
    scrollerStyle: NSScroller.Style
  ) -> CGFloat {
    thinWidth
  }

  override public func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {
    // Keep slot completely transparent for a clean borderless look
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
    Self.knobColor.setFill()
    path.fill()
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
public struct ThinRedScrollbarsModifier: ViewModifier {
  public func body(content: Content) -> some View {
    content.background(ThinRedScrollbarsConfigurator())
  }
}

public extension View {
  func thinRedScrollbars() -> some View {
    modifier(ThinRedScrollbarsModifier())
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
  func makeNSView(context: Context) -> ThinRedScrollbarsConfiguratorView {
    ThinRedScrollbarsConfiguratorView()
  }

  func updateNSView(_ nsView: ThinRedScrollbarsConfiguratorView, context: Context) {
    nsView.scheduleConfiguration()
  }
}

private final class ThinRedScrollbarsConfiguratorView: NSView {
  private var configurationScheduled = false
  private var pendingWindowIDs = Set<ObjectIdentifier>()
  private var pendingWindows: [NSWindow] = []
  private var windowObservers: [NSObjectProtocol] = []

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
    if let targetWindow = targetWindow ?? window {
      let identifier = ObjectIdentifier(targetWindow)
      if pendingWindowIDs.insert(identifier).inserted {
        pendingWindows.append(targetWindow)
      }
    }

    guard !configurationScheduled else { return }
    configurationScheduled = true
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      configurationScheduled = false
      let windows = pendingWindows
      pendingWindows.removeAll(keepingCapacity: true)
      pendingWindowIDs.removeAll(keepingCapacity: true)
      for targetWindow in windows {
        guard let contentView = targetWindow.contentView else { continue }
        ThinRedScroller.install(in: contentView)
      }
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
        self?.scheduleConfiguration(for: targetWindow)
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

  deinit {
    removeWindowObservers()
  }
}
