import Foundation

func vitePressFiles(
  profile: SiteProfile,
  draft: ArticleDraft,
  siteName: String,
  description: String,
  baseURL: String,
  deploymentTarget: SiteStarterDeploymentTarget
) -> [StarterFile] {
  var files = [
    StarterFile(
      path: "package.json",
      contents: nodePackageJSON(
        siteName: siteName,
        scripts: [
          "dev": "vitepress dev docs",
          "build": "vitepress build docs",
          "preview": "vitepress preview docs",
        ],
        dependencies: ["vitepress": "latest"]
      )
    ),
    StarterFile(
      path: "docs/.vitepress/config.mts",
      contents: vitePressConfig(siteName: siteName, description: description, baseURL: baseURL)
    ),
    StarterFile(path: "docs/index.md", contents: vitePressHome(siteName: siteName, description: description)),
    StarterFile(
      path: draft.repositoryPath?.nilIfEmpty ?? "docs/posts/welcome.md",
      contents: FrontMatterRenderer().renderDocument(draft: draft, profile: profile)
    ),
    StarterFile(path: ".gitignore", contents: "docs/.vitepress/cache/\ndocs/.vitepress/dist/\nnode_modules/\n.DS_Store\n"),
    StarterFile(
      path: "README.md",
      contents: readme(siteName: siteName, kind: "VitePress", buildCommand: buildCommand(for: .vitePress))
    ),
    StarterFile(
      path: "DEPLOYMENT.md",
      contents: deploymentGuide(siteName: siteName, kind: "VitePress", branch: profile.branch, target: deploymentTarget)
    ),
  ]
  if deploymentTarget == .githubPages {
    files.append(
      StarterFile(
        path: ".github/workflows/pages.yml",
        contents: genericGitHubPagesWorkflow(branch: profile.branch, siteKind: .vitePress)
      )
    )
  }
  files.append(contentsOf: deploymentConfigFiles(target: deploymentTarget, siteKind: .vitePress, siteName: siteName))
  return files
}

func vitePressConfig(siteName: String, description: String, baseURL: String) -> String {
  let basePath = normalizedVitePressBasePath(baseURL)
  return """
  import { defineConfig } from 'vitepress'

  export default defineConfig({
    lang: 'zh-Hans',
    title: \(jsonStringLiteral(siteName)),
    description: \(jsonStringLiteral(description)),
    base: \(jsonStringLiteral(basePath)),
    themeConfig: {
      nav: [
        { text: '首页', link: '/' },
        { text: '文章', link: '/posts/welcome' }
      ],
      sidebar: [
        {
          text: '开始使用',
          items: [{ text: '欢迎文章', link: '/posts/welcome' }]
        }
      ],
      search: { provider: 'local' }
    }
  })
  """
}

func normalizedVitePressBasePath(_ baseURL: String) -> String {
  guard let components = URLComponents(string: baseURL), !components.path.isEmpty else {
    return "/"
  }
  let path = components.path.hasPrefix("/") ? components.path : "/\(components.path)"
  return path.hasSuffix("/") ? path : "\(path)/"
}

func vitePressHome(siteName: String, description: String) -> String {
  """
  ---
  layout: home

  hero:
    name: \(jsonStringLiteral(siteName))
    text: \(jsonStringLiteral(description))
    tagline: 从第一篇 Markdown 文档开始。
    actions:
      - theme: brand
        text: 开始阅读
        link: /posts/welcome

  features:
    - title: Markdown 优先
      details: 使用普通 Markdown 维护内容。
    - title: 本地搜索
      details: 无需额外服务即可搜索文档。
    - title: GitHub Pages
      details: 内置可直接部署的 Actions 工作流。
  ---
  """
}
