import Foundation

func hugoFiles(
  profile: SiteProfile,
  draft: ArticleDraft,
  siteName: String,
  description: String,
  author: String,
  baseURL: String,
  deploymentTarget: SiteStarterDeploymentTarget
) -> [StarterFile] {
  var files = [
    StarterFile(
      path: "hugo.toml",
      contents: hugoConfig(
        siteName: siteName,
        description: description,
        author: author,
        baseURL: baseURL
      )
    ),
    StarterFile(path: "layouts/_default/baseof.html", contents: hugoBaseLayout(siteName: siteName)),
    StarterFile(path: "layouts/index.html", contents: hugoIndexLayout()),
    StarterFile(path: "layouts/_default/single.html", contents: hugoSingleLayout()),
    StarterFile(
      path: draft.repositoryPath?.nilIfEmpty ?? "content/posts/welcome.md",
      contents: FrontMatterRenderer().renderDocument(draft: draft, profile: profile)
    ),
    StarterFile(path: "static/css/site.css", contents: starterCSS()),
    StarterFile(path: ".gitignore", contents: "public/\nresources/_gen/\n.DS_Store\n"),
    StarterFile(path: "README.md", contents: readme(siteName: siteName, kind: "Hugo", buildCommand: buildCommand(for: .hugo))),
    StarterFile(
      path: "DEPLOYMENT.md",
      contents: deploymentGuide(siteName: siteName, kind: "Hugo", branch: profile.branch, target: deploymentTarget)
    ),
  ]
  if deploymentTarget == .githubPages {
    files.append(
      StarterFile(
        path: ".github/workflows/pages.yml",
        contents: genericGitHubPagesWorkflow(branch: profile.branch, siteKind: .hugo)
      )
    )
  }
  files.append(contentsOf: deploymentConfigFiles(target: deploymentTarget, siteKind: .hugo, siteName: siteName))
  return files
}

func hugoConfig(
  siteName: String,
  description: String,
  author: String,
  baseURL: String
) -> String {
  """
  baseURL = "\(escapedTOMLStringContent(baseURL))"
  languageCode = "zh-Hans"
  title = "\(escapedTOMLStringContent(siteName))"

  [params]
  description = "\(escapedTOMLStringContent(description))"
  author = "\(escapedTOMLStringContent(author))"
  """
}

func hugoBaseLayout(siteName: String) -> String {
  let escapedSiteName = escapedHTMLText(siteName)
  return """
  <!doctype html>
  <html lang="zh-Hans">
  <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>{{ block "title" . }}\(escapedSiteName){{ end }}</title>
    <link rel="stylesheet" href="/css/site.css">
  </head>
  <body>
    <header class="site-header"><a class="brand" href="/">\(escapedSiteName)</a></header>
    <main class="site-main">{{ block "main" . }}{{ end }}</main>
  </body>
  </html>
  """
}

func hugoIndexLayout() -> String {
  """
  {{ define "main" }}
  <section class="intro">
    <h1>{{ .Site.Title }}</h1>
    <p>{{ .Site.Params.description }}</p>
  </section>
  <section class="post-list">
    {{ range first 10 .Site.RegularPages }}
    <article>
      <a href="{{ .RelPermalink }}">{{ .Title }}</a>
      <p>{{ .Summary }}</p>
    </article>
    {{ end }}
  </section>
  {{ end }}
  """
}

func hugoSingleLayout() -> String {
  """
  {{ define "title" }}{{ .Title }} · {{ .Site.Title }}{{ end }}
  {{ define "main" }}
  <article class="post">
    <h1>{{ .Title }}</h1>
    <p class="meta">{{ .Date.Format "2006-01-02" }}</p>
    {{ .Content }}
  </article>
  {{ end }}
  """
}
