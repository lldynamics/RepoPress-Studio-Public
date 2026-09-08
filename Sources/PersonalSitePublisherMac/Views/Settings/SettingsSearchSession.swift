import Foundation

/// Search navigation is local to this Settings view, separate from saved preferences.
struct SettingsSearchSession {
  private(set) var query = ""
  private(set) var isShowingResults = true
  private(set) var highlight: SettingsSearchHighlight?

  var canReturnToResults: Bool {
    !isShowingResults && !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  var sidebarQuery: String { isShowingResults ? query : "" }

  mutating func updateQuery(_ query: String) {
    self.query = query
    showResults()
  }

  mutating func open(_ item: SettingsSearchItem) {
    isShowingResults = false
    highlight = SettingsSearchHighlight(
      subsection: SettingsSubsection.section(forSearchItemID: item.id)
        ?? SettingsSubsection.defaultSection(for: item.tab)
    )
  }

  mutating func showResults() {
    isShowingResults = true
    highlight = nil
  }

  mutating func dismissHighlight(id: UUID? = nil) {
    guard id == nil || highlight?.id == id else { return }
    highlight = nil
  }
}

struct SettingsSearchHighlight: Equatable, Identifiable {
  let id = UUID()
  let subsection: SettingsSubsection

  /// Intersect the target section with the detail viewport so the cue follows
  /// native scrolling and never draws over the page header or adjacent panes.
  func visibleFrame(
    anchorFrames: [SettingsSubsection: CGRect],
    viewport: CGRect
  ) -> CGRect? {
    guard let anchor = anchorFrames[subsection], anchor.width > 0 else { return nil }
    let nextTop =
      SettingsSubsection.sections(for: subsection.tab)
      .compactMap { section -> CGFloat? in
        guard let frame = anchorFrames[section], frame.minY > anchor.minY else { return nil }
        return frame.minY
      }
      .min() ?? viewport.maxY
    let sectionFrame = CGRect(
      x: anchor.minX,
      y: anchor.minY,
      width: anchor.width,
      height: max(0, nextTop - anchor.minY)
    )
    let visible = sectionFrame.intersection(viewport)
    return visible.isNull || visible.isEmpty ? nil : visible
  }
}
