import Foundation

func zolaFiles(
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
      path: "config.toml",
      contents: """
      base_url = "\(baseURL)"
      title = "\(escapedTOML(siteName))"
      description = "\(escapedTOML(description))"
      default_language = "zh-Hans"
      compile_sass = false
      build_search_index = true
      generate_feeds = true

      [markdown]
      highlight_code = true
      smart_punctuation = true

      [extra]
      author = "\(escapedTOML(author))"
      """
    ),
    StarterFile(path: ".gitignore", contents: "public/\n.DS_Store\n"),
    StarterFile(path: "content/_index.md", contents: zolaSectionFrontMatter(siteName: siteName, sortBy: "date")),
    StarterFile(path: draft.repositoryPath?.nilIfEmpty ?? "content/posts/welcome.md", contents: FrontMatterRenderer().renderDocument(draft: draft, profile: profile)),
    StarterFile(path: "templates/base.html", contents: zolaBaseTemplate(siteName: siteName)),
    StarterFile(path: "templates/index.html", contents: zolaIndexTemplate()),
    StarterFile(path: "templates/section.html", contents: zolaSectionTemplate()),
    StarterFile(path: "templates/page.html", contents: zolaPageTemplate()),
    StarterFile(path: "static/css/site.css", contents: starterCSS()),
    StarterFile(path: "README.md", contents: readme(siteName: siteName, kind: "Zola", buildCommand: "zola build")),
    StarterFile(path: "DEPLOYMENT.md", contents: deploymentGuide(siteName: siteName, kind: "Zola", branch: profile.branch, target: deploymentTarget)),
  ]

  if deploymentTarget == .githubPages {
    files.append(StarterFile(path: ".github/workflows/pages.yml", contents: zolaGitHubPagesWorkflow(branch: profile.branch)))
  }
  files.append(contentsOf: deploymentConfigFiles(target: deploymentTarget, siteKind: .zola, siteName: siteName))
  return files
}

func escapedTOML(_ text: String) -> String {
  text.replacingOccurrences(of: "\\", with: "\\\\")
    .replacingOccurrences(of: "\"", with: "\\\"")
}

func zolaSectionFrontMatter(siteName: String, sortBy: String) -> String {
  """
  +++
  title = "\(siteName)"
  sort_by = "\(sortBy)"
  template = "index.html"
  page_template = "page.html"
  +++

  """
}

func zolaBaseTemplate(siteName: String) -> String {
  """
  <!doctype html>
  <html lang="zh-Hans">
  <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>{% block title %}\(siteName){% endblock title %}</title>
    <link rel="stylesheet" href="{{ get_url(path="css/site.css") }}">
  </head>
  <body>
    <header class="site-header">
      <a class="brand" href="{{ get_url(path="/") }}">\(siteName)</a>
    </header>
    <main class="site-main">
      {% block content %}{% endblock content %}
    </main>
  </body>
  </html>
  """
}

func zolaIndexTemplate() -> String {
  return """
  {% extends "base.html" %}
  {% block content %}
  <section class="intro">
    <h1>{{ section.title }}</h1>
    <p>{{ config.description }}</p>
  </section>
  <section>
    <h2>最新文章</h2>
    <div class="post-list">
      {% for page in section.pages %}
      <article>
        <a href="{{ page.permalink | safe }}">{{ page.title }}</a>
        <p>{{ page.summary | default(value="") }}</p>
      </article>
      {% endfor %}
    </div>
  </section>
  {% endblock content %}
  """
}

func zolaSectionTemplate() -> String {
  """
  {% extends "index.html" %}
  """
}

func zolaPageTemplate() -> String {
  """
  {% extends "base.html" %}
  {% block title %}{{ page.title }} · {{ config.title }}{% endblock title %}
  {% block content %}
  <article class="post">
    <h1>{{ page.title }}</h1>
    <p class="meta">{{ page.date }}</p>
    {{ page.content | safe }}
  </article>
  {% endblock content %}
  """
}

func zolaGitHubPagesWorkflow(branch: String) -> String {
  """
  name: Deploy Zola site to GitHub Pages

  on:
    push:
      branches: [\(branch)]
    workflow_dispatch:

  permissions:
    contents: read
    pages: write
    id-token: write

  concurrency:
    group: pages
    cancel-in-progress: false

  jobs:
    build:
      runs-on: ubuntu-latest
      steps:
        - uses: actions/checkout@v4
        - uses: taiki-e/install-action@v2
          with:
            tool: zola
        - run: zola build
        - uses: actions/upload-pages-artifact@v3
          with:
            path: public

    deploy:
      environment:
        name: github-pages
        url: ${{ steps.deployment.outputs.page_url }}
      runs-on: ubuntu-latest
      needs: build
      steps:
        - id: deployment
          uses: actions/deploy-pages@v4
  """
}
