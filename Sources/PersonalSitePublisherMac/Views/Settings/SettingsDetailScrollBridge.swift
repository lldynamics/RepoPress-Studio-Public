import AppKit
import SwiftUI

/// The only information that crosses from the detail scroll view into SwiftUI.
enum SettingsDetailScrollBoundaryDirection: Equatable, Sendable {
  case previous
  case next

  var arrival: SettingsDetailScrollArrival {
    switch self {
    case .previous: return .bottom
    case .next: return .top
    }
  }
}

enum SettingsDetailScrollArrival: Equatable, Sendable {
  case top
  case bottom
}

struct SettingsDetailScrollArrivalRequest: Equatable, Sendable {
  let id: UUID
  let edge: SettingsDetailScrollArrival

  init(edge: SettingsDetailScrollArrival, id: UUID = UUID()) {
    self.id = id
    self.edge = edge
  }
}

/// Shared across rebuilt subsection views so one physical gesture cannot
/// cascade through multiple short settings pages.
@MainActor
final class SettingsDetailScrollHandoffGate {
  private static let mouseWheelIdleInterval: TimeInterval = 0.25
  private var isLocked = false
  private var lastPhaseLessEventTimestamp: TimeInterval?

  func prepareForEvent(
    phase: NSEvent.Phase,
    momentumPhase: NSEvent.Phase,
    timestamp: TimeInterval
  ) {
    if phase.contains(.began) || phase.contains(.ended) || phase.contains(.cancelled)
      || momentumPhase.contains(.ended) || momentumPhase.contains(.cancelled)
    {
      reset()
      return
    }

    guard phase.isEmpty, momentumPhase.isEmpty else { return }

    if let lastPhaseLessEventTimestamp,
      timestamp - lastPhaseLessEventTimestamp > Self.mouseWheelIdleInterval
    {
      reset()
    }
    lastPhaseLessEventTimestamp = timestamp
  }

  func lock() -> Bool {
    guard !isLocked else { return false }
    isLocked = true
    return true
  }

  private func reset() {
    isLocked = false
    lastPhaseLessEventTimestamp = nil
  }
}

/// Pure boundary policy. AppKit reports a positive delta when the pointer is
/// moving up and a negative delta when it is moving down.
enum SettingsDetailScrollBoundaryPolicy {
  static func direction(
    forVerticalDelta deltaY: CGFloat,
    atTop: Bool,
    atBottom: Bool
  ) -> SettingsDetailScrollBoundaryDirection? {
    guard deltaY != 0 else { return nil }
    if deltaY > 0, atTop { return .previous }
    if deltaY < 0, atBottom { return .next }
    return nil
  }
}

/// Styling for the settings detail owner. Indicators are hidden, while the
/// scroll view remains fully scrollable by wheel, trackpad, keyboard, and
/// accessibility actions.
enum SettingsDetailScrollViewStyling {
  @MainActor
  static func install(on scrollView: NSScrollView) {
    scrollView.hasVerticalScroller = false
    scrollView.hasHorizontalScroller = false
    scrollView.autohidesScrollers = true
    scrollView.horizontalScrollElasticity = .none
  }
}

struct SettingsDetailScrollBridge: NSViewRepresentable {
  let arrivalRequest: SettingsDetailScrollArrivalRequest?
  let handoffGate: SettingsDetailScrollHandoffGate
  let onBoundaryCrossing: @MainActor (SettingsDetailScrollBoundaryDirection) -> Void

  init(
    arrivalRequest: SettingsDetailScrollArrivalRequest? = nil,
    handoffGate: SettingsDetailScrollHandoffGate,
    onBoundaryCrossing: @escaping @MainActor (SettingsDetailScrollBoundaryDirection) -> Void
  ) {
    self.arrivalRequest = arrivalRequest
    self.handoffGate = handoffGate
    self.onBoundaryCrossing = onBoundaryCrossing
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(
      handoffGate: handoffGate,
      onBoundaryCrossing: onBoundaryCrossing
    )
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
    context.coordinator.onBoundaryCrossing = onBoundaryCrossing
    context.coordinator.handoffGate = handoffGate
    context.coordinator.connect(marker: nsView)
    context.coordinator.updateArrivalRequest(arrivalRequest)
  }

  static func dismantleNSView(_ nsView: MarkerView, coordinator: Coordinator) {
    coordinator.disconnect()
  }

  @MainActor
  final class Coordinator {
    var handoffGate: SettingsDetailScrollHandoffGate
    var onBoundaryCrossing: @MainActor (SettingsDetailScrollBoundaryDirection) -> Void
    private weak var marker: MarkerView?
    private weak var scrollView: NSScrollView?
    private var eventMonitor: Any?
    private var pendingArrivalRequest: SettingsDetailScrollArrivalRequest?
    private var appliedArrivalRequestID: UUID?
    private var arrivalGeneration = 0
    private var connectionGeneration = 0
    private var connectionRetriesScheduled = false
    private var stylingGeneration = 0

    init(
      handoffGate: SettingsDetailScrollHandoffGate,
      onBoundaryCrossing: @escaping @MainActor (SettingsDetailScrollBoundaryDirection) -> Void
    ) {
      self.handoffGate = handoffGate
      self.onBoundaryCrossing = onBoundaryCrossing
    }

    func connect(marker: MarkerView) {
      self.marker = marker
      guard let candidate = Self.detailScrollView(for: marker) else {
        scheduleConnectionRetries(for: marker)
        return
      }
      connectionRetriesScheduled = false
      connectionGeneration += 1
      if scrollView !== candidate {
        disconnect()
        self.marker = marker
        scrollView = candidate
        appliedArrivalRequestID = nil
        installMonitor()
        applyPendingArrivalIfNeeded()
      }
      scheduleStyling(for: candidate)
    }

    func disconnect() {
      if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
      eventMonitor = nil
      scrollView = nil
      arrivalGeneration += 1
      connectionGeneration += 1
      connectionRetriesScheduled = false
      stylingGeneration += 1
    }

    func updateArrivalRequest(_ request: SettingsDetailScrollArrivalRequest?) {
      pendingArrivalRequest = request
      applyPendingArrivalIfNeeded()
    }

    private func applyPendingArrivalIfNeeded() {
      guard let request = pendingArrivalRequest,
        request.id != appliedArrivalRequestID,
        scrollView != nil
      else { return }

      appliedArrivalRequestID = request.id
      arrivalGeneration += 1
      let generation = arrivalGeneration
      for delay in [0.0, 0.05, 0.15] {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
          guard let self, self.arrivalGeneration == generation else { return }
          self.scroll(to: request.edge)
        }
      }
    }

    private func scroll(to arrival: SettingsDetailScrollArrival) {
      guard let scrollView, let documentView = scrollView.documentView else { return }
      let clipView = scrollView.contentView
      let documentBounds = documentView.bounds
      let minimumY = documentBounds.minY
      let maximumY = max(minimumY, documentBounds.maxY - clipView.bounds.height)
      let y: CGFloat
      if documentView.isFlipped {
        y = arrival == .top ? minimumY : maximumY
      } else {
        y = arrival == .top ? maximumY : minimumY
      }
      clipView.scroll(to: NSPoint(x: clipView.bounds.origin.x, y: y))
      scrollView.reflectScrolledClipView(clipView)
    }

    private func installMonitor() {
      eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) {
        [weak self] event in
        guard let self else { return event }
        return self.handle(event) ? nil : event
      }
    }

    private func scheduleStyling(for target: NSScrollView) {
      stylingGeneration += 1
      let generation = stylingGeneration
      for delay in [0.0, 0.05, 0.15, 0.35, 0.65, 1.0] {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak target] in
          guard let self, self.stylingGeneration == generation,
            let target, self.scrollView === target
          else { return }
          SettingsDetailScrollViewStyling.install(on: target)
        }
      }
    }

    private func handle(_ event: NSEvent) -> Bool {
      guard let scrollView,
        let window = scrollView.window,
        event.window === window,
        let hitView = window.contentView?.hitTest(event.locationInWindow),
        Self.enclosingScrollView(of: hitView) === scrollView
      else { return false }

      handoffGate.prepareForEvent(
        phase: event.phase,
        momentumPhase: event.momentumPhase,
        timestamp: event.timestamp
      )

      // Ended/cancelled events only release the gesture lock. They must not
      // become a second handoff at the same edge.
      guard !event.phase.contains(.ended), !event.phase.contains(.cancelled) else {
        return false
      }

      // Momentum is allowed to finish the native scroll, but it must not
      // carry one physical gesture through multiple settings subsections.
      guard event.momentumPhase.isEmpty else { return false }

      let boundaries = Self.boundaries(of: scrollView)
      guard
        let direction = SettingsDetailScrollBoundaryPolicy.direction(
          forVerticalDelta: event.scrollingDeltaY,
          atTop: boundaries.atTop,
          atBottom: boundaries.atBottom
        ), handoffGate.lock()
      else { return false }

      onBoundaryCrossing(direction)
      return true
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

    private static func boundaries(of scrollView: NSScrollView) -> (
      atTop: Bool,
      atBottom: Bool
    ) {
      guard let documentView = scrollView.documentView else {
        return (true, true)
      }
      let visibleBounds = scrollView.documentVisibleRect
      let documentBounds = documentView.bounds
      let tolerance: CGFloat = 0.5
      if documentView.isFlipped {
        return (
          visibleBounds.minY <= documentBounds.minY + tolerance,
          visibleBounds.maxY >= documentBounds.maxY - tolerance
        )
      }
      return (
        visibleBounds.maxY >= documentBounds.maxY - tolerance,
        visibleBounds.minY <= documentBounds.minY + tolerance
      )
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
