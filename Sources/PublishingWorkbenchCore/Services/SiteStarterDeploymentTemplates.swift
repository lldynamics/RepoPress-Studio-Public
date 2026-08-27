import Foundation

func jsonStringLiteral(_ value: String) -> String {
  let encoder = JSONEncoder()
  encoder.outputFormatting = .withoutEscapingSlashes
  guard let data = try? encoder.encode(value),
        let literal = String(data: data, encoding: .utf8) else {
    return "\"\""
  }
  return literal
}

func escapedTOMLStringContent(_ value: String) -> String {
  value
    .replacingOccurrences(of: "\\", with: "\\\\")
    .replacingOccurrences(of: "\"", with: "\\\"")
    .replacingOccurrences(of: "\n", with: "\\n")
    .replacingOccurrences(of: "\r", with: "\\r")
}

func escapedHTMLText(_ value: String) -> String {
  value
    .replacingOccurrences(of: "&", with: "&amp;")
    .replacingOccurrences(of: "<", with: "&lt;")
    .replacingOccurrences(of: ">", with: "&gt;")
    .replacingOccurrences(of: "\"", with: "&quot;")
    .replacingOccurrences(of: "'", with: "&#39;")
}

func starterCSS() -> String {
  """
  :root {
    color-scheme: light dark;
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
  }
  body {
    margin: 0;
    color: CanvasText;
    background: Canvas;
  }
  .site-header {
    border-bottom: 1px solid color-mix(in srgb, CanvasText 14%, transparent);
    padding: 18px clamp(20px, 6vw, 72px);
  }
  .brand {
    color: inherit;
    font-weight: 700;
    text-decoration: none;
  }
  .site-main {
    max-width: 760px;
    padding: 42px clamp(20px, 6vw, 72px);
  }
  h1 {
    font-size: clamp(2rem, 4vw, 3.25rem);
    line-height: 1.1;
  }
  a {
    color: LinkText;
  }
  .post-list article {
    border-top: 1px solid color-mix(in srgb, CanvasText 12%, transparent);
    padding: 18px 0;
  }
  .meta {
    color: color-mix(in srgb, CanvasText 58%, transparent);
  }
  """
}

func readme(siteName: String, kind: String, buildCommand: String) -> String {
  """
  # \(siteName)

  这个站点由 PersonalSitePublisherMac 的 Site Starter 生成。

  ## 本地预览

  - \(kind): `\(buildCommand)`

  ## 使用现成主题

  Site Starter 维护 Astro、Hugo、Zola 和 VitePress 四套现代起点；如果你想使用现成视觉主题，建议直接克隆主题仓库，再导入已有站点：

  ```bash
  git clone <主题仓库地址> <本地站点目录>
  ```

  回到工作台选择“导入已有站点”。导入会保留主题文件，只读取已有站点的内容和 Git 信息。

  ## 后续发布

  在 Mac 版发布控制台中写文章、检查 Front Matter 和图片，再通过同步/部署工作区推送到 GitHub Pages。
  """
}

func deploymentGuide(siteName: String, kind: String, branch: String) -> String {
  """
  # \(siteName) 部署说明

  已生成 GitHub Pages 工作流。第一次推送后，在 GitHub 仓库的 Settings > Pages 中选择 GitHub Actions 作为部署来源。

  ## 第一次推送

  ```bash
  git add .
  git commit -m 'Initial site'
  git push -u origin \(posixShellQuote(branch))
  ```

  ## 后续发布

  在发布控制台完成写作、发布检查、Diff 确认和提交后，推送到 `\(branch)` 分支即可触发 GitHub Pages 构建。

  ## 构建器

  当前模板：\(kind)
  """
}

func deploymentGuide(
  siteName: String,
  kind: String,
  branch: String,
  target: SiteStarterDeploymentTarget
) -> String {
  let targetLine = target == .none ? "暂不绑定外部部署平台。" : "部署目标：\(target.displayName)。"
  return deploymentGuide(siteName: siteName, kind: kind, branch: branch) + "\n\n\(targetLine)\n"
}

func deploymentConfigFiles(
  target: SiteStarterDeploymentTarget,
  siteKind: SiteKind,
  siteName: String
) -> [StarterFile] {
  switch target {
  case .netlify:
    return [
      StarterFile(
        path: "netlify.toml",
        contents: """
        [build]
        command = "\(buildCommand(for: siteKind))"
        publish = "\(publishDirectory(for: siteKind))"
        """
      ),
    ]
  case .vercel:
    return [
      StarterFile(
        path: "vercel.json",
        contents: """
        {
          "name": "\(SlugService.slug(from: siteName).nilIfEmpty ?? "starter-site")",
          "buildCommand": "\(buildCommand(for: siteKind))",
          "outputDirectory": "\(publishDirectory(for: siteKind))"
        }
        """
      ),
    ]
  case .cloudflarePages:
    return [
      StarterFile(
        path: "wrangler.toml",
        contents: """
        name = "\(SlugService.slug(from: siteName).nilIfEmpty ?? "starter-site")"
        pages_build_output_dir = "\(publishDirectory(for: siteKind))"
        compatibility_date = "2026-07-08"
        """
      ),
    ]
  case .githubPages, .none:
    return []
  }
}

func buildCommand(for siteKind: SiteKind) -> String {
  switch siteKind {
  case .zola:
    return "zola build"
  case .astro, .vitePress, .nextJS, .hexo:
    return "npm run build"
  case .quartz:
    return "npx quartz build"
  case .foam:
    return "npx @foam/cli export . --out public"
  case .hugo:
    return "hugo --minify"
  case .jekyll:
    return "bundle exec jekyll build"
  }
}

func publishDirectory(for siteKind: SiteKind) -> String {
  switch siteKind {
  case .astro:
    return "dist"
  case .vitePress:
    return "docs/.vitepress/dist"
  case .nextJS:
    return "out"
  case .jekyll:
    return "_site"
  case .zola, .hugo, .quartz, .foam, .hexo:
    return "public"
  }
}

func genericGitHubPagesWorkflow(branch: String, siteKind: SiteKind) -> String {
  let setupStep: String
  switch siteKind {
  case .astro, .vitePress, .nextJS, .quartz, .foam, .hexo:
    setupStep = """
        - uses: actions/setup-node@v4
          with:
            node-version: 22
        - run: npm install
    """
  case .hugo:
    setupStep = """
        - uses: peaceiris/actions-hugo@v3
          with:
            hugo-version: latest
    """
  case .zola:
    setupStep = """
        - uses: taiki-e/install-action@v2
          with:
            tool: zola
    """
  case .jekyll:
    setupStep = """
        - uses: ruby/setup-ruby@v1
          with:
            bundler-cache: true
    """
  }
  return """
  name: Deploy static site to GitHub Pages

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
  \(setupStep)
        - run: \(buildCommand(for: siteKind))
        - uses: actions/upload-pages-artifact@v3
          with:
            path: \(publishDirectory(for: siteKind))

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
