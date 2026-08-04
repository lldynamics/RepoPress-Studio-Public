#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RENDERER="$ROOT_DIR/script/run_app_store_screenshot_renderer.sh"

fail() {
  echo "app store marketing screenshot: $*" >&2
  exit 1
}

[[ "$#" -eq 3 ]] || fail "usage: compose_app_store_marketing_screenshot.sh <screenshot-id> <source-png> <output-png>"
id="$1"
input="$2"
output="$3"
language="${SCREENSHOT_MARKETING_LANGUAGE:-zh-Hans}"
[[ -s "$input" ]] || fail "source image is missing or empty: $input"

case "$language" in
  zh-Hans)
    case "$id" in
      writing)
        title="写作与预览，一屏完成"
        subtitle="专注 Markdown 内容，边写边确认最终呈现效果"
        ;;
      ai-chat)
        title="免费接入你的 AI 服务"
        subtitle="自备 API Key，基于文章上下文辅助写作"
        ;;
      sync-api-publish)
        title="从仓库检查到发布，流程清晰可控"
        subtitle="连接 GitHub 或 GitLab，在操作前确认状态与差异"
        ;;
      seo-social-preview)
        title="发布前看清 SEO 与分享效果"
        subtitle="集中检查摘要、图片和社交分享信息"
        ;;
      deployment-status)
        title="部署状态与异常，一处掌握"
        subtitle="检查常用静态站点托管服务和自定义端点"
        ;;
      maintenance)
        title="持续整理内容，而不只是发布"
        subtitle="发现旧文章、分类问题、失效链接与维护任务"
        ;;
      general-drafts)
        title="跨站点管理草稿与文章"
        subtitle="全文搜索、通用草稿和站点内容集中处理"
        ;;
      privacy-lock)
        title="需要时快速遮挡工作区内容"
        subtitle="手动隐藏界面，并遮挡标记为私密的文章信息"
        ;;
      knowledge-library)
        title="把写作资料整理成本地知识库"
        subtitle="导入、搜索与关联资料，让内容始终留在写作上下文中"
        ;;
      *) fail "unknown screenshot id: $id" ;;
    esac
    ;;
  en)
    case "$id" in
      writing)
        title="Write and Preview in One Workspace"
        subtitle="Stay focused on Markdown while checking the final result as you write"
        ;;
      ai-chat)
        title="Use Your Own AI Service—for Free"
        subtitle="Bring your API key and keep your writing context on this Mac"
        ;;
      sync-api-publish)
        title="From Repository Checks to Publishing"
        subtitle="Connect GitHub or GitLab and review status and changes before every action"
        ;;
      seo-social-preview)
        title="Preview SEO and Social Sharing Before You Publish"
        subtitle="Review summaries, images, and sharing metadata in one place"
        ;;
      deployment-status)
        title="See Deployment Health and Issues in One Place"
        subtitle="Validate popular static-site hosts and custom endpoints"
        ;;
      maintenance)
        title="Keep Content Healthy After Publishing"
        subtitle="Find stale articles, taxonomy issues, broken links, and maintenance tasks"
        ;;
      general-drafts)
        title="Manage Drafts and Articles Across Sites"
        subtitle="Search everything and organize general drafts and site content together"
        ;;
      privacy-lock)
        title="Hide Your Workspace in One Click"
        subtitle="Shield the interface and mask articles marked private"
        ;;
      knowledge-library)
        title="Turn Research into a Local Knowledge Library"
        subtitle="Import, search, and connect references without leaving your writing workflow"
        ;;
      *) fail "unknown screenshot id: $id" ;;
    esac
    ;;
  *)
    fail "unsupported marketing screenshot language: $language"
    ;;
esac

bash "$RENDERER" marketing "$input" "$output" "$title" "$subtitle"

properties="$(sips -g pixelWidth -g pixelHeight -g hasAlpha "$output" 2>/dev/null)" \
  || fail "could not inspect rendered output"
width="$(printf '%s\n' "$properties" | awk '/pixelWidth:/ { print $2; exit }')"
height="$(printf '%s\n' "$properties" | awk '/pixelHeight:/ { print $2; exit }')"
alpha="$(printf '%s\n' "$properties" | awk '/hasAlpha:/ { print $2; exit }')"
[[ "$width" == "2880" && "$height" == "1800" ]] \
  || fail "unexpected output dimensions: ${width}x${height}"
[[ "$alpha" == "no" ]] || fail "output still has an alpha channel"

echo "app store marketing screenshot: wrote $output (2880x1800, alpha-free)"
