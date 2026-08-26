import Foundation

/// The static-site generator used by a publishing profile.
public enum SiteKind: String, Codable, CaseIterable, Identifiable, Sendable {
  case zola
  case astro
  case hugo
  case vitePress
  case nextJS
  case quartz
  case foam
  case hexo
  case jekyll

  public var id: String { rawValue }
}

/// The front matter serialization style used by a publishing profile.
public enum FrontMatterStyle: String, Codable, CaseIterable, Identifiable, Sendable {
  case yaml
  case toml

  public var id: String { rawValue }
}

/// The validation policy applied to a publishing profile's slugs.
public enum SiteSlugValidationRule: String, Codable, CaseIterable, Identifiable, Sendable {
  case lowercaseKebab
  case relaxed
  case disabled

  public var id: String { rawValue }
}

/// The value-only publishing layout selected for a site kind.
public struct SitePublishingDefaults: Codable, Hashable, Sendable {
  public var siteKind: SiteKind
  public var frontMatterStyle: FrontMatterStyle
  public var contentRoot: String
  public var assetRoot: String
  public var markdownPathPattern: String
  public var imagePathPattern: String
  public var publicImagePathPattern: String
  public var dateFormat: String
  public var includeDraftFlagInFrontMatter: Bool
  public var includeCoverInFrontMatter: Bool
  public var slugValidationRule: SiteSlugValidationRule

  public init(
    siteKind: SiteKind,
    frontMatterStyle: FrontMatterStyle,
    contentRoot: String,
    assetRoot: String,
    markdownPathPattern: String,
    imagePathPattern: String,
    publicImagePathPattern: String,
    dateFormat: String,
    includeDraftFlagInFrontMatter: Bool,
    includeCoverInFrontMatter: Bool,
    slugValidationRule: SiteSlugValidationRule
  ) {
    self.siteKind = siteKind
    self.frontMatterStyle = frontMatterStyle
    self.contentRoot = contentRoot
    self.assetRoot = assetRoot
    self.markdownPathPattern = markdownPathPattern
    self.imagePathPattern = imagePathPattern
    self.publicImagePathPattern = publicImagePathPattern
    self.dateFormat = dateFormat
    self.includeDraftFlagInFrontMatter = includeDraftFlagInFrontMatter
    self.includeCoverInFrontMatter = includeCoverInFrontMatter
    self.slugValidationRule = slugValidationRule
  }
}
