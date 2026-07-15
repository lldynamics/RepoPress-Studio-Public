import Foundation

enum ContentHealthContextFilter: String, CaseIterable, Identifiable {
  case overview
  case publicRisks
  case aiFixes
  case siteIssues
  case maintenance

  var id: String { rawValue }
}

enum RepositoryContextStage: String, CaseIterable, Identifiable {
  case overview
  case changes
  case publishing
  case automation
  case preview
  case history

  var id: String { rawValue }
}
