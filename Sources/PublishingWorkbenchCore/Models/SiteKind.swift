import Foundation

public enum SiteKind: String, Codable, CaseIterable, Identifiable, Sendable {
  case zola
  case astro
  case hugo
  case hexo
  case jekyll

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .zola:
      return "Zola"
    case .astro:
      return "Astro"
    case .hugo:
      return "Hugo"
    case .hexo:
      return "Hexo"
    case .jekyll:
      return "Jekyll"
    }
  }

  public var coverFrontMatterFieldName: String {
    switch self {
    case .zola:
      return "og_preview_img"
    case .jekyll:
      return "image"
    case .astro, .hugo, .hexo:
      return "cover"
    }
  }

  public var coverFrontMatterDisplayPath: String {
    switch self {
    case .zola:
      return "extra.og_preview_img"
    case .jekyll:
      return "image"
    case .astro, .hugo, .hexo:
      return "cover"
    }
  }
}

public enum FrontMatterStyle: String, Codable, CaseIterable, Identifiable, Sendable {
  case yaml
  case toml

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .yaml:
      return "YAML"
    case .toml:
      return "TOML"
    }
  }
}

public enum SiteSlugValidationRule: String, Codable, CaseIterable, Identifiable, Sendable {
  case lowercaseKebab
  case relaxed
  case disabled

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .lowercaseKebab:
      return "小写/CJK 连字符"
    case .relaxed:
      return "宽松英文/CJK"
    case .disabled:
      return "只检查非空"
    }
  }

  public var detail: String {
    switch self {
    case .lowercaseKebab:
      return "允许小写字母、数字、CJK 字符和连字符。"
    case .relaxed:
      return "允许英文大小写、数字、CJK 字符、下划线和连字符。"
    case .disabled:
      return "只要求 slug 非空，适合沿用旧仓库路径。"
    }
  }
}
