import SwiftUI

/// A zero-height, stable target at the beginning of a Settings subsection.
///
/// Settings pages place this immediately before each subsection's content.
/// `ScrollViewReader` uses the stable ID for sidebar/deep-link navigation;
/// the frame preference lets the Settings shell keep its selection in sync
/// when the user scrolls manually.
struct SettingsSubsectionAnchor: View {
  static let coordinateSpaceName = "settings-subsection-scroll-content"

  let subsection: SettingsSubsection

  var body: some View {
    GeometryReader { proxy in
      Color.clear.preference(
        key: SettingsSubsectionAnchorFramePreferenceKey.self,
        value: [subsection: proxy.frame(in: .named(Self.coordinateSpaceName))]
      )
    }
    .frame(height: 0)
    .id(subsection.id)
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}

struct SettingsSubsectionAnchorFramePreferenceKey: PreferenceKey {
  static let defaultValue: [SettingsSubsection: CGRect] = [:]

  static func reduce(
    value: inout [SettingsSubsection: CGRect],
    nextValue: () -> [SettingsSubsection: CGRect]
  ) {
    value.merge(nextValue(), uniquingKeysWith: { _, newest in newest })
  }
}

enum SettingsSubsectionVisibilityPolicy {
  /// The active line is close to the top of the detail viewport. This keeps
  /// a section selected while its heading is visible, including a short final
  /// section that never reaches the exact top edge.
  static let activationLine: CGFloat = 16

  static func visibleSubsection(
    in tab: SettingsTab,
    anchorFrames: [SettingsSubsection: CGRect],
    isAtBottom: Bool = false
  ) -> SettingsSubsection? {
    let tabSubsections = SettingsSubsection.sections(for: tab)
    let anchors = tabSubsections.compactMap { subsection in
      anchorFrames[subsection].map { (subsection, $0.minY) }
    }
    guard !anchors.isEmpty else { return nil }

    if isAtBottom,
      let lastVisibleSubsection = tabSubsections.last(where: { anchorFrames[$0] != nil })
    {
      return lastVisibleSubsection
    }

    if let passedAnchor =
      anchors
      .filter({ $0.1 <= activationLine })
      .max(by: { $0.1 < $1.1 })
    {
      return passedAnchor.0
    }

    return anchors.min(by: { $0.1 < $1.1 })?.0
  }
}

struct SettingsSubsectionScrollRequest: Equatable, Identifiable {
  let id: UUID
  let subsection: SettingsSubsection

  init(subsection: SettingsSubsection, id: UUID = UUID()) {
    self.id = id
    self.subsection = subsection
  }
}
