import Foundation

struct StarterFile {
  var path: String
  var contents: String
}

extension SiteStarterService {
  func template(for id: SiteStarterTemplateID) throws -> SiteStarterTemplate {
    guard let template = SiteStarterTemplate.builtIn.first(where: { $0.id == id }) else {
      throw SiteStarterError.unknownTemplate(id.rawValue)
    }
    return template
  }

  func starterFiles(
    profile: SiteProfile,
    draft: ArticleDraft,
    template: SiteStarterTemplate,
    siteName: String,
    description: String,
    author: String,
    baseURL: String,
    deploymentTarget: SiteStarterDeploymentTarget
  ) -> [StarterFile] {
    switch template.id {
    case .zolaPersonalBlog:
      return zolaFiles(
        profile: profile,
        draft: draft,
        siteName: siteName,
        description: description,
        author: author,
        baseURL: baseURL,
        deploymentTarget: deploymentTarget
      )
    case .astroPersonalBlog:
      return astroFiles(
        profile: profile,
        draft: draft,
        siteName: siteName,
        description: description,
        baseURL: baseURL,
        deploymentTarget: deploymentTarget
      )
    case .hugoPersonalBlog:
      return hugoFiles(
        profile: profile,
        draft: draft,
        siteName: siteName,
        description: description,
        author: author,
        baseURL: baseURL,
        deploymentTarget: deploymentTarget
      )
    case .vitePressDocumentation:
      return vitePressFiles(
        profile: profile,
        draft: draft,
        siteName: siteName,
        description: description,
        baseURL: baseURL,
        deploymentTarget: deploymentTarget
      )
    }
  }
}
