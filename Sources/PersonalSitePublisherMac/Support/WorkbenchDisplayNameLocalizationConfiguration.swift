import PublishingWorkbenchCore

extension SiteKind {
  var workbenchDisplayNameSemanticKey: String {
    switch self {
    case .zola: "display.site-kind.zola"
    case .astro: "display.site-kind.astro"
    case .hugo: "display.site-kind.hugo"
    case .hexo: "display.site-kind.hexo"
    case .jekyll: "display.site-kind.jekyll"
    }
  }

  var fallbackDisplayName: String {
    switch self {
    case .zola: "Zola"
    case .astro: "Astro"
    case .hugo: "Hugo"
    case .hexo: "Hexo"
    case .jekyll: "Jekyll"
    }
  }
}

extension FrontMatterStyle {
  var workbenchDisplayNameSemanticKey: String {
    switch self {
    case .yaml: "display.front-matter-style.yaml"
    case .toml: "display.front-matter-style.toml"
    }
  }

  var fallbackDisplayName: String {
    switch self {
    case .yaml: "YAML"
    case .toml: "TOML"
    }
  }
}

extension SiteSlugValidationRule {
  var workbenchDisplayNameSemanticKey: String {
    switch self {
    case .lowercaseKebab: "display.site-slug-validation-rule.lowercase-kebab"
    case .relaxed: "display.site-slug-validation-rule.relaxed"
    case .disabled: "display.site-slug-validation-rule.disabled"
    }
  }

  var fallbackDisplayName: String {
    switch self {
    case .lowercaseKebab: "小写/CJK 连字符"
    case .relaxed: "宽松英文/CJK"
    case .disabled: "只检查非空"
    }
  }
}

extension RepositoryProvider {
  var workbenchDisplayNameSemanticKey: String {
    switch self {
    case .github: "display.repository-provider.github"
    case .gitlab: "display.repository-provider.gitlab"
    }
  }

  var fallbackDisplayName: String {
    switch self {
    case .github: "GitHub"
    case .gitlab: "GitLab"
    }
  }
}

extension RepositoryPublishStrategy {
  var workbenchDisplayNameSemanticKey: String {
    switch self {
    case .direct: "display.repository-publish-strategy.direct"
    case .reviewRequest: "display.repository-publish-strategy.review-request"
    }
  }

  var fallbackDisplayName: String {
    switch self {
    case .direct: "直接提交"
    case .reviewRequest: "分支 + PR/MR"
    }
  }
}

extension SiteProfilePurpose {
  var workbenchDisplayNameSemanticKey: String {
    switch self {
    case .publishing: "display.site-profile-purpose.publishing"
    case .repositoryBackup: "display.site-profile-purpose.repository-backup"
    case .generalDraftBackup: "display.site-profile-purpose.general-draft-backup"
    }
  }

  var fallbackDisplayName: String {
    switch self {
    case .publishing: "连接仓库并发布"
    case .repositoryBackup: "连接仓库备份"
    case .generalDraftBackup: "素材库"
    }
  }
}

extension AIProviderPreset {
  var workbenchDisplayNameSemanticKey: String {
    switch self {
    case .openAICompatible: "display.ai-provider-preset.openai-compatible"
    case .deepSeek: "display.ai-provider-preset.deepseek"
    case .openRouter: "display.ai-provider-preset.openrouter"
    case .local: "display.ai-provider-preset.local"
    case .custom: "display.ai-provider-preset.custom"
    }
  }

  var fallbackDisplayName: String {
    switch self {
    case .openAICompatible: "Custom Endpoint (Compatible)"
    case .deepSeek: "DeepSeek"
    case .openRouter: "OpenRouter"
    case .local: "本地模型"
    case .custom: "自定义"
    }
  }
}

extension AIWritingStylePreset {
  var workbenchDisplayNameSemanticKey: String {
    switch self {
    case .jinfangZola: "display.ai-writing-style-preset.jinfang-zola"
    case .technicalNote: "display.ai-writing-style-preset.technical-note"
    case .personalEssay: "display.ai-writing-style-preset.personal-essay"
    case .custom: "display.ai-writing-style-preset.custom"
    }
  }

  var fallbackDisplayName: String {
    switch self {
    case .jinfangZola: "锦方 Zola"
    case .technicalNote: "技术笔记"
    case .personalEssay: "个人随笔"
    case .custom: "自定义"
    }
  }
}

extension DeploymentProvider {
  var workbenchDisplayNameSemanticKey: String {
    switch self {
    case .githubPages: "display.deployment-provider.github-pages"
    case .gitlabPages: "display.deployment-provider.gitlab-pages"
    case .netlify: "display.deployment-provider.netlify"
    case .vercel: "display.deployment-provider.vercel"
    case .cloudflarePages: "display.deployment-provider.cloudflare-pages"
    case .custom: "display.deployment-provider.custom"
    }
  }

  var fallbackDisplayName: String {
    switch self {
    case .githubPages: "GitHub Pages"
    case .gitlabPages: "GitLab Pages"
    case .netlify: "Netlify"
    case .vercel: "Vercel"
    case .cloudflarePages: "Cloudflare Pages"
    case .custom: "自定义端点"
    }
  }
}

extension SiteStarterDeploymentTarget {
  var workbenchDisplayNameSemanticKey: String {
    switch self {
    case .githubPages: "display.site-starter-deployment-target.github-pages"
    case .netlify: "display.site-starter-deployment-target.netlify"
    case .vercel: "display.site-starter-deployment-target.vercel"
    case .cloudflarePages: "display.site-starter-deployment-target.cloudflare-pages"
    case .none: "display.site-starter-deployment-target.none"
    }
  }

  var fallbackDisplayName: String {
    switch self {
    case .githubPages: "GitHub Pages"
    case .netlify: "Netlify"
    case .vercel: "Vercel"
    case .cloudflarePages: "Cloudflare Pages"
    case .none: "暂不部署"
    }
  }
}
