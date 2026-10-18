import Foundation
import Observation
import SwiftUI
import os

/// The single multiplier behind every workbench font.
///
/// macOS text styles never follow a system text-size preference: caption,
/// caption2 and footnote stay at 10pt and body at 13pt everywhere. Workbench
/// fonts therefore derive from the macOS base sizes below, multiplied by this
/// scale, so one value can enlarge the interface consistently.
enum WorkbenchTextScale {
  static let standard: CGFloat = 1
  static let shared = WorkbenchTextScaleState(
    preference: .resolved(
      rawValue: UserDefaults.standard.string(forKey: WorkbenchTextScalePreference.storageKey))
  )

  static var current: CGFloat {
    shared.scale
  }
}

/// Font tokens can be read outside main-actor views. Reads remain thread-safe,
/// while preference changes on the main actor invalidate the views that read them.
final class WorkbenchTextScaleState: Observable, Sendable {
  private let registrar = ObservationRegistrar()
  private let storage: OSAllocatedUnfairLock<CGFloat>

  init(preference: WorkbenchTextScalePreference) {
    storage = OSAllocatedUnfairLock(initialState: preference.scale)
  }

  var scale: CGFloat {
    registrar.access(self, keyPath: \.scale)
    return storage.withLock { $0 }
  }

  @MainActor
  func apply(_ preference: WorkbenchTextScalePreference) {
    guard storage.withLock({ $0 }) != preference.scale else { return }
    registrar.withMutation(of: self, keyPath: \.scale) {
      storage.withLock { $0 = preference.scale }
    }
  }
}

private struct WorkbenchTypographyModifier: ViewModifier {
  @AppStorage(WorkbenchTextScalePreference.storageKey)
  private var preferenceRawValue = WorkbenchTextScalePreference.standard.rawValue

  func body(content: Content) -> some View {
    content
      .font(.workbenchBody)
      .onChange(of: preferenceRawValue, initial: true) { _, value in
        WorkbenchTextScale.shared.apply(.resolved(rawValue: value))
      }
  }
}

extension View {
  /// Apply at each scene root so native labels inherit the same default font.
  /// Observation updates existing views without resetting their identity or state.
  func workbenchTypography() -> some View {
    modifier(WorkbenchTypographyModifier())
  }
}

extension Font {
  // Size levels. Base sizes are the macOS text-style sizes; at the standard
  // scale each level returns the system text style itself, so the default
  // appearance matches the platform exactly.
  static var workbenchMetadata: Font { workbenchLevel(.subheadline, baseSize: 11) }
  static var workbenchBody: Font { workbenchLevel(.body, baseSize: 13) }
  static var workbenchHeadline: Font { workbenchLevel(.headline, baseSize: 13, weight: .bold) }
  static var workbenchTitle3: Font { workbenchLevel(.title3, baseSize: 15) }
  static var workbenchTitle2: Font { workbenchLevel(.title2, baseSize: 17) }
  static var workbenchTitle: Font { workbenchLevel(.title, baseSize: 22) }
  static var workbenchLargeTitle: Font { workbenchLevel(.largeTitle, baseSize: 26) }

  // Semantic roles keep page hierarchy consistent. Metadata never goes below
  // 11pt; supporting copy and item titles use the 13pt body size.
  static var workbenchPageTitle: Font { workbenchTitle2.weight(.semibold) }
  static var workbenchPageSubtitle: Font { workbenchBody }
  static var workbenchSectionTitle: Font { workbenchTitle3.weight(.semibold) }
  static var workbenchItemTitle: Font { workbenchBody.weight(.medium) }
  static var workbenchSupporting: Font { workbenchBody }
  static var workbenchButtonLabel: Font { workbenchBody.weight(.medium) }
  static var workbenchCardTitle: Font { workbenchBody.weight(.semibold) }
  static var workbenchMetricValue: Font { workbenchTitle3.weight(.semibold) }

  private static func workbenchLevel(
    _ textStyle: Font,
    baseSize: CGFloat,
    weight: Font.Weight = .regular
  ) -> Font {
    let scale = WorkbenchTextScale.current
    guard scale != WorkbenchTextScale.standard else { return textStyle }
    return .system(size: (baseSize * scale).rounded(), weight: weight)
  }
}
