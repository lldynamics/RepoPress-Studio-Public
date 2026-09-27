import Foundation

public enum DraftFullTextSearchScope: String, CaseIterable, Identifiable, Codable, Sendable {
  case allDrafts
  case currentSite
  case allSites
  case generalDrafts

  public var id: String { rawValue }
}
