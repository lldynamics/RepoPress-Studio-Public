import AppKit
import SwiftUI

/// Narrow AppKit support for the one native scroll owner in each Settings tab.
///
/// SwiftUI remains responsible for targets and selection. AppKit only exposes
/// reliable scroll notifications on macOS 14 so preference-based anchor frames
/// are reevaluated while a Form or ScrollView is moved by any input method.
struct SettingsDetailScrollPosition: Equatable, Sendable {
  let isAtBottom: Bool
  let visibleOriginY: CGFloat
}

struct SettingsDetailScrollBridge: NSViewRepresentable {
  let onScroll: @MainActor (SettingsDetailScrollPosition) -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(onScroll: onScroll)
  }

  func makeNSView(context: Context) -> MarkerView {
    let view = MarkerView()
    view.onMove = { [weak coordinator = context.coordinator, weak view] in
      guard let view else { return }
      coordinator?.connect(marker: view)
    }
    return view
  }

  func updateNSView(_ nsView: MarkerView, context: Context) {
    context.coordinator.onScroll = onScroll
    context.coordinator.connect(marker: nsView)
  }

  static func dismantleNSView(_ nsView: MarkerView, coordinator: Coordinator) {
    coordinator.disconnect()
  }

  @MainActor
  final class Coordinator {
    var onScroll: @MainActor (SettingsDetailScrollPosition) -> Void
    private weak var scrollView: NSScrollView?
    private var boundsObserver: NSObjectProtocol?
    private var connectionGeneration = 0
    private var connectionRetriesScheduled = false
    private var latestScrollPosition: SettingsDetailScrollPosition?
    private var scrollNotificationScheduled = false

    init(onScroll: @escaping @MainActor (SettingsDetailScrollPosition) -> Void) {
      self.onScroll = onScroll
    }

    func connect(marker: MarkerView) {
      guard let candidate = Self.detailScrollView(for: marker) else {
        scheduleConnectionRetries(for: marker)
        return
      }
      connectionRetriesScheduled = false
      guard scrollView !== candidate else { return }

      disconnect()
      scrollView = candidate
      SettingsDetailScrollViewStyling.install(on: candidate)
      candidate.contentView.postsBoundsChangedNotifications = true
      boundsObserver = NotificationCenter.default.addObserver(
        forName: NSView.boundsDidChangeNotification,
        object: candidate.contentView,
        queue: .main
      ) { [weak self] _ in
        // The observer is explicitly delivered by OperationQueue.main. Keep
        // the coalescing mutation synchronous so a burst does not first create
        // one unstructured Task per bounds notification.
        MainActor.assumeIsolated {
          self?.scheduleScrollNotification()
        }
      }
      notifyScroll()
    }

    func disconnect() {
      if let boundsObserver {
        NotificationCenter.default.removeObserver(boundsObserver)
      }
      boundsObserver = nil
      scrollView = nil
      latestScrollPosition = nil
      scrollNotificationScheduled = false
      connectionGeneration += 1
      connectionRetriesScheduled = false
    }

    private func scheduleConnectionRetries(for marker: MarkerView) {
      guard !connectionRetriesScheduled else { return }
      connectionRetriesScheduled = true
      connectionGeneration += 1
      let generation = connectionGeneration
      let delays = [0.0, 0.05, 0.15, 0.35]
      for (index, delay) in delays.enumerated() {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak marker] in
          guard let self, self.connectionGeneration == generation, let marker else { return }
          if Self.detailScrollView(for: marker) != nil {
            self.connectionRetriesScheduled = false
            self.connect(marker: marker)
          } else if index == delays.indices.last {
            self.connectionRetriesScheduled = false
          }
        }
      }
    }

    private func notifyScroll() {
      guard let scrollView else { return }
      let position = SettingsDetailScrollPosition(
        isAtBottom: Self.isAtBottom(scrollView),
        visibleOriginY: scrollView.documentVisibleRect.minY
      )
      guard latestScrollPosition != position else { return }
      latestScrollPosition = position
      onScroll(position)
    }

    /// Bounds notifications can arrive many times during a single trackpad
    /// frame. Coalesce them on the main run loop; the visible-subsection work
    /// only needs the latest position.
    private func scheduleScrollNotification() {
      guard !scrollNotificationScheduled else { return }
      scrollNotificationScheduled = true
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        self.scrollNotificationScheduled = false
        self.notifyScroll()
      }
    }

    private static func isAtBottom(_ scrollView: NSScrollView) -> Bool {
      guard let documentView = scrollView.documentView else { return true }
      let visibleBounds = scrollView.documentVisibleRect
      let documentBounds = documentView.bounds
      let tolerance: CGFloat = 0.5
      if documentView.isFlipped {
        return visibleBounds.maxY >= documentBounds.maxY - tolerance
      }
      return visibleBounds.minY <= documentBounds.minY + tolerance
    }

    private static func detailScrollView(for marker: MarkerView) -> NSScrollView? {
      if let enclosing = enclosingScrollView(of: marker) {
        return enclosing
      }
      guard let contentView = marker.window?.contentView else { return nil }
      let markerPoint = marker.convert(
        NSPoint(x: marker.bounds.midX, y: marker.bounds.midY),
        to: nil
      )
      return scrollViews(in: contentView)
        .filter { scrollView in
          let point = scrollView.convert(markerPoint, from: nil)
          return scrollView.bounds.insetBy(dx: -2, dy: -2).contains(point)
        }
        .max { lhs, rhs in
          lhs.bounds.width * lhs.bounds.height < rhs.bounds.width * rhs.bounds.height
        }
    }

    private static func scrollViews(in view: NSView) -> [NSScrollView] {
      var result: [NSScrollView] = []
      if let scrollView = view as? NSScrollView {
        result.append(scrollView)
      }
      for subview in view.subviews {
        result.append(contentsOf: scrollViews(in: subview))
      }
      return result
    }

    private static func enclosingScrollView(of view: NSView) -> NSScrollView? {
      var current: NSView? = view
      while let candidate = current {
        if let scrollView = candidate as? NSScrollView { return scrollView }
        current = candidate.superview
      }
      return nil
    }
  }

  @MainActor
  final class MarkerView: NSView {
    var onMove: @MainActor () -> Void = {}

    override func viewDidMoveToSuperview() {
      super.viewDidMoveToSuperview()
      onMove()
    }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      onMove()
    }
  }
}

/// Keep Settings scrollbars under the user's system preference. The native
/// scroll view remains responsible for pointer, keyboard and VoiceOver input.
@MainActor
enum SettingsDetailScrollViewStyling {
  static func install(on scrollView: NSScrollView) {
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = false
    scrollView.scrollerStyle = NSScroller.preferredScrollerStyle
    scrollView.autohidesScrollers = NSScroller.preferredScrollerStyle == .overlay
    scrollView.horizontalScrollElasticity = .none
  }
}
