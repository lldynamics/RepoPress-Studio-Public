import Foundation

/// The persisted identity of an independent content window. A typed route
/// prevents a draft and a knowledge document with the same UUID from sharing
/// a SwiftUI window instance.
enum PopOutWindowTarget: Codable, Hashable {
  case draft(UUID)
  case reference(UUID)
}
