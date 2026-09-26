import Foundation

public enum ArticleVisibility: String, Codable, CaseIterable, Identifiable, Sendable {
  case `public`
  case `private`

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .public:
      return "公开"
    case .private:
      return "私密"
    }
  }

  public var systemImage: String {
    switch self {
    case .public:
      return "globe"
    case .private:
      return "lock"
    }
  }
}
