import Foundation

func astroFiles(
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
        scripts: ["dev": "astro dev", "build": "astro build", "preview": "astro preview"],
        dependencies: ["@astrojs/mdx": "latest", "astro": "latest"]
      )
    ),
    StarterFile(path: "astro.config.mjs", contents: astroConfig(baseURL: baseURL)),
    StarterFile(path: "src/pages/index.astro", contents: astroIndex(siteName: siteName, description: description)),
    StarterFile(
      path: draft.repositoryPath?.nilIfEmpty ?? "src/content/blog/welcome.mdx",
      contents: FrontMatterRenderer().renderDocument(draft: draft, profile: profile)
    ),
    StarterFile(path: "src/styles/site.css", contents: starterCSS()),
    StarterFile(path: ".gitignore", contents: "dist/\nnode_modules/\n.DS_Store\n"),
    StarterFile(path: "README.md", contents: readme(siteName: siteName, kind: "Astro", buildCommand: buildCommand(for: .astro))),
    StarterFile(
      path: "DEPLOYMENT.md",
      contents: deploymentGuide(siteName: siteName, kind: "Astro", branch: profile.branch, target: deploymentTarget)
    ),
  ]
  if deploymentTarget == .githubPages {
    files.append(
      StarterFile(
        path: ".github/workflows/pages.yml",
        contents: genericGitHubPagesWorkflow(branch: profile.branch, siteKind: .astro)
      )
    )
  }
  files.append(contentsOf: deploymentConfigFiles(target: deploymentTarget, siteKind: .astro, siteName: siteName))
  return files
}

func nodePackageJSON(
  siteName: String,
  scripts: [String: String],
  dependencies: [String: String]
) -> String {
  let scriptsText = scripts.keys.sorted().map { key in
    "    \"\(key)\": \"\(scripts[key] ?? "")\""
  }.joined(separator: ",\n")
  let dependenciesText = dependencies.keys.sorted().map { key in
    "    \"\(key)\": \"\(dependencies[key] ?? "")\""
  }.joined(separator: ",\n")
  return """
  {
    "name": "\(SlugService.slug(from: siteName).nilIfEmpty ?? "starter-site")",
    "version": "0.1.0",
    "private": true,
    "scripts": {
  \(scriptsText)
    },
    "dependencies": {
  \(dependenciesText)
    }
  }
  """
}

func astroConfig(baseURL: String) -> String {
  """
  import { defineConfig } from 'astro/config';
  import mdx from '@astrojs/mdx';

  export default defineConfig({
    site: \(jsonStringLiteral(baseURL)),
    integrations: [mdx()]
  });
  """
}

func astroIndex(siteName: String, description: String) -> String {
  let escapedSiteName = escapedHTMLText(siteName)
  let escapedDescription = escapedHTMLText(description)
  return """
  ---
  import '../styles/site.css';
  ---
  <html lang="zh-Hans">
    <head>
      <meta charset="utf-8" />
      <meta name="viewport" content="width=device-width" />
      <title>\(escapedSiteName)</title>
    </head>
    <body>
      <header class="site-header">
        <a class="brand" href="/">\(escapedSiteName)</a>
      </header>
      <main class="site-main">
        <h1>\(escapedSiteName)</h1>
        <p>\(escapedDescription)</p>
        <section class="post-list">
          <article>
            <a href="/blog/welcome/">欢迎文章</a>
            <p>从第一篇内容开始扩展你的 Astro 网站。</p>
          </article>
        </section>
      </main>
    </body>
  </html>
  """
}
