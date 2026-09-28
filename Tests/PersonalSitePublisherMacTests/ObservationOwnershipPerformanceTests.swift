import AppKit
import Combine
import Observation
import SwiftUI
import XCTest

/// Opt-in comparison of the observation systems used by AIBatchMaintenancePanel.
/// The message-only view must remain subscribed to `message`, rather than to the
/// whole model, when the model uses the Observation framework.
@MainActor
final class ObservationOwnershipPerformanceTests: XCTestCase {
  fileprivate final class ObservableObjectModel: ObservableObject {
    @Published var message = "Ready"
    @Published var queues: [Int] = []
  }

  @Observable
  fileprivate final class ObservationModel {
    var message = "Ready"
    var queues: [Int] = []
  }

  private final class RenderCounter {
    var lastValue = -1
    var renderCount = 0

    func record(_ value: Int) {
      lastValue = value
      renderCount += 1
    }
  }

  private struct ObservableObjectMessageView: View {
    @ObservedObject private var model: ObservableObjectModel
    let counter: RenderCounter

    init(model: ObservableObjectModel, counter: RenderCounter) {
      _model = ObservedObject(wrappedValue: model)
      self.counter = counter
    }

    var body: some View {
      counter.record(model.message == "Ready" ? 0 : 1)
      return Text(model.message)
    }
  }

  private struct ObservationMessageView: View {
    let model: ObservationModel
    let counter: RenderCounter

    var body: some View {
      counter.record(model.message == "Ready" ? 0 : 1)
      return Text(model.message)
    }
  }

  func testMessageOnlyViewDoesNotRedrawWhenQueuesChange() throws {
    try XCTSkipUnless(
      ProcessInfo.processInfo.environment["RUN_OBSERVATION_OWNERSHIP_BENCHMARK"] == "1",
      "Set RUN_OBSERVATION_OWNERSHIP_BENCHMARK=1 to run the opt-in observation comparison."
    )
    _ = NSApplication.shared

    let iterations = 40
    let observableObject = sampleObservableObject(iterations: iterations)
    let observation = sampleObservation(iterations: iterations)
    print(
      "message-only redraws after \(iterations) queues updates: "
        + "ObservableObject=\(observableObject.renderCount), "
        + "@Observable=\(observation.renderCount)"
    )
    XCTAssertGreaterThan(
      observableObject.renderCount,
      1,
      "ObservableObject should publish queue changes to the whole observed object."
    )
    XCTAssertEqual(
      observation.renderCount,
      1,
      "A message-only @Observable view should not redraw when only queues change."
    )
  }

  private func sampleObservableObject(iterations: Int) -> (renderCount: Int, elapsed: Double) {
    let model = ObservableObjectModel()
    let counter = RenderCounter()
    let hostingView = NSHostingView(
      rootView: ObservableObjectMessageView(model: model, counter: counter)
    )
    return sample(
      iterations: iterations, model: model, counter: counter, hostingView: hostingView
    ) {
      $0.queues.append($1)
    }
  }

  private func sampleObservation(iterations: Int) -> (renderCount: Int, elapsed: Double) {
    let model = ObservationModel()
    let counter = RenderCounter()
    let hostingView = NSHostingView(
      rootView: ObservationMessageView(model: model, counter: counter)
    )
    return sample(
      iterations: iterations, model: model, counter: counter, hostingView: hostingView
    ) {
      $0.queues.append($1)
    }
  }

  private func sample<Model, Content: View>(
    iterations: Int,
    model: Model,
    counter: RenderCounter,
    hostingView: NSHostingView<Content>,
    update: (Model, Int) -> Void
  ) -> (renderCount: Int, elapsed: Double) {
    hostingView.frame = NSRect(x: 0, y: 0, width: 160, height: 50)
    hostingView.layoutSubtreeIfNeeded()
    let start = ContinuousClock.now
    for value in 0..<iterations {
      update(model, value)
      _ = RunLoop.current.run(
        mode: .default,
        before: Date()
      )
      hostingView.layoutSubtreeIfNeeded()
    }
    let elapsed = start.duration(to: ContinuousClock.now)
    return (
      counter.renderCount,
      Double(elapsed.components.seconds)
        + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000_000
    )
  }
}
