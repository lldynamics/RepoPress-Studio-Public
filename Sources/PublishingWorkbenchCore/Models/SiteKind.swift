import PublishingCoreSupport
import PublishingDomainContracts

public extension SiteKind {
  var displayName: String {
    switch self {
    case .zola:
      return "Zola"
    case .astro:
      return "Astro"
    case .hugo:
      return "Hugo"
    case .vitePress:
      return "VitePress"
    case .nextJS:
      return "Next.js (Contentlayer / Velite)"
    case .quartz:
      return "Quartz"
    case .foam:
      return "Foam"
    case .hexo:
      return "Hexo"
    case .jekyll:
      return "Jekyll"
    }
  }

  var coverFrontMatterFieldName: String {
    switch self {
    case .zola:
      return "og_preview_img"
    case .jekyll:
      return "image"
    case .quartz:
      return "socialImage"
    case .foam:
      return "image"
    case .astro, .hugo, .vitePress, .nextJS, .hexo:
      return "cover"
    }
  }

  var coverFrontMatterDisplayPath: String {
    switch self {
    case .zola:
      return "extra.og_preview_img"
    case .jekyll:
      return "image"
    case .quartz:
      return "socialImage"
    case .foam:
      return "image"
    case .astro, .hugo, .vitePress, .nextJS, .hexo:
      return "cover"
    }
  }
}

public extension FrontMatterStyle {
  var displayName: String {
    switch self {
    case .yaml:
      return "YAML"
    case .toml:
      return "TOML"
    }
  }
}

public extension SiteSlugValidationRule {
  var displayName: String {
    switch self {
    case .lowercaseKebab:
      return "小写/CJK 连字符"
    case .relaxed:
      return "宽松英文/CJK"
    case .disabled:
      return "只检查非空"
    }
  }

  var detail: String {
    switch self {
    case .lowercaseKebab:
      return CoreL10n.text("允许小写字母、数字、CJK 字符和连字符。")
    case .relaxed:
      return CoreL10n.text("允许英文大小写、数字、CJK 字符、下划线和连字符。")
    case .disabled:
      return CoreL10n.text("只要求 slug 非空，适合沿用旧仓库路径。")
    }
  }
}
