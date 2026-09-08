import CoreGraphics
import Foundation
import PublishingWorkbenchCore

enum MarkdownOutlinePresentationPolicy {
  static let dockMinimumWidth: CGFloat = 920

  static func usesDockedLayout(isPinned: Bool, availableWidth: CGFloat) -> Bool {
    isPinned && availableWidth >= dockMinimumWidth
  }

  static func activeItemID(
    in items: [MarkdownOutlineItem],
    selectedRange: NSRange
  ) -> String? {
    items.last(where: { $0.headingLocation <= selectedRange.location })?.id
  }

  static func visibleItems(
    _ items: [MarkdownOutlineItem],
    collapsedItemIDs: Set<String>
  ) -> [MarkdownOutlineItem] {
    var collapsedLevel: Int?
    return items.filter { item in
      if let level = collapsedLevel {
        if item.level > level { return false }
        collapsedLevel = nil
      }
      if collapsedItemIDs.contains(item.id) {
        collapsedLevel = item.level
      }
      return true
    }
  }
}
