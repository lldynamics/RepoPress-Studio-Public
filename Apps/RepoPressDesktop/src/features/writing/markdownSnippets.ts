import type { TextRange } from "./markdownWriting";

export type MarkdownSnippetKind = "articleTemplate" | "snippet";
export interface MarkdownSnippet { id: string; label: string; description?: string; shortcut: string; kind: MarkdownSnippetKind; template: string; selectionToken?: string }
export interface MarkdownSnippetExpansionContext { title?: string; slug?: string; date?: string }
export const BUILT_IN_MARKDOWN_SNIPPETS: MarkdownSnippet[] = [
  { id: "tutorial", label: "教程文章", description: "背景、步骤、验证和常见问题", shortcut: "tutorial", kind: "articleTemplate", template: "# {{title}}\n\n## 背景\n\n简要说明问题与适用场景。\n\n## 操作步骤\n\n1. 第一步\n2. 第二步\n3. 第三步\n\n## 验证结果\n\n说明如何确认操作成功。\n\n## 常见问题\n\n### 问题一\n\n补充答案。\n" },
  { id: "review", label: "评测文章", description: "结论、优缺点、适用人群与建议", shortcut: "review", kind: "articleTemplate", template: "# {{title}}\n\n## 结论先行\n\n写下最重要的判断。\n\n## 优点\n\n- （待补充）\n\n## 局限\n\n- （待补充）\n\n## 适合谁\n\n## 最终建议\n" },
  { id: "callout", label: "提示框", description: "插入 Astro/Hexo 常见的提示容器", shortcut: "callout", kind: "snippet", template: "::: tip 提示\n在这里输入提示内容。\n:::", selectionToken: "在这里输入提示内容。" },
  { id: "ssg-lead", label: "导语短代码", description: "插入 Hugo lead 导语容器", shortcut: "lead", kind: "snippet", template: "{{< lead >}}\n在这里输入文章导语。\n{{< /lead >}}", selectionToken: "在这里输入文章导语。" },
  { id: "ssg-youtube", label: "YouTube 视频", description: "插入视频短代码并替换 VIDEO_ID", shortcut: "youtube", kind: "snippet", template: "{{< youtube VIDEO_ID >}}", selectionToken: "VIDEO_ID" },
  { id: "ssg-bilibili", label: "B 站视频", description: "插入视频短代码并替换 BV_ID", shortcut: "bilibili", kind: "snippet", template: "{{< bilibili BV_ID >}}", selectionToken: "BV_ID" },
  { id: "ssg-github-card", label: "GitHub 卡片", description: "插入 GitHub 卡片并替换 owner/repo", shortcut: "github", kind: "snippet", template: "{{< github-card owner/repo >}}", selectionToken: "owner/repo" },
  { id: "ssg-figure", label: "图片短代码", description: "插入 Hugo figure 图片短代码", shortcut: "figure", kind: "snippet", template: "{{< figure src=\"/images/example.jpg\" title=\"图片说明\" >}}", selectionToken: "/images/example.jpg" },
  { id: "details", label: "折叠详情", description: "插入 details/summary 区块", shortcut: "details", kind: "snippet", template: "<details>\n<summary>查看详情</summary>\n\n在这里补充内容。\n\n</details>", selectionToken: "在这里补充内容。" },
  { id: "footnote", label: "脚注", description: "插入脚注引用与定义", shortcut: "footnote", kind: "snippet", template: "这里需要补充说明[^note]。\n\n[^note]: 脚注内容。", selectionToken: "脚注内容" },
  { id: "mermaid", label: "Mermaid 基础流程图", description: "插入可在预览中渲染的流程图", shortcut: "mermaid", kind: "snippet", template: "```mermaid\nflowchart TD\n  A[开始] --> B[处理]\n  B --> C[完成]\n```" },
];
const custom = new Map<string, MarkdownSnippet[]>();
const clamp = (source: string, range: TextRange): TextRange => { const a = Math.max(0, Math.min(source.length, range.from)); const b = Math.max(0, Math.min(source.length, range.to)); return { from: Math.min(a, b), to: Math.max(a, b) }; };
export function normalizeSnippetShortcut(value: string): string { const normalized = value.normalize("NFKC").trim().toLocaleLowerCase().replace(/^\/+/, ""); return /^[\p{L}\p{N}_-]+$/u.test(normalized) ? normalized : ""; }
export function expandMarkdownSnippet(snippet: MarkdownSnippet, context: MarkdownSnippetExpansionContext = {}): string {
  const now = new Date(); const date = context.date ?? `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, "0")}-${String(now.getDate()).padStart(2, "0")}`;
  return snippet.template.replace(/\{\{(title|slug|date)\}\}/g, (_, key) => key === "date" ? date : context[key as "title" | "slug"] ?? (key === "title" ? "未命名文章" : ""));
}
export function availableMarkdownSnippets(scope: string, customSnippets: MarkdownSnippet[] = custom.get(scope) ?? []): MarkdownSnippet[] { return [...BUILT_IN_MARKDOWN_SNIPPETS, ...customSnippets]; }
export function replaceCustomMarkdownSnippets(scope: string, snippets: MarkdownSnippet[]): MarkdownSnippet[] { const next = snippets.slice(-100); custom.set(scope, next); return [...next]; }
export function saveCustomMarkdownSnippet(scope: string, snippet: MarkdownSnippet): MarkdownSnippet[] { const shortcut = normalizeSnippetShortcut(snippet.shortcut); const label = snippet.label.trim(); const template = snippet.template.trim(); if (!label || !template || !shortcut || BUILT_IN_MARKDOWN_SNIPPETS.some((item) => item.id === snippet.id || item.shortcut === shortcut)) return [...(custom.get(scope) ?? [])]; const list = (custom.get(scope) ?? []).filter((item) => item.id !== snippet.id && item.shortcut !== shortcut); list.push({ ...snippet, label, template, shortcut }); custom.set(scope, list.slice(-100)); return [...custom.get(scope)!]; }
export function removeCustomMarkdownSnippet(scope: string, id: string): MarkdownSnippet[] { const list = (custom.get(scope) ?? []).filter((item) => item.id !== id); custom.set(scope, list); return list; }
export function insertMarkdownSnippet(source: string, selection: TextRange, snippet: MarkdownSnippet, context: MarkdownSnippetExpansionContext = {}): { text: string; selection: TextRange } {
  const range = clamp(source, selection); let value = expandMarkdownSnippet(snippet, context);
  const token = snippet.selectionToken ? expandMarkdownSnippet({ ...snippet, template: snippet.selectionToken }, context) : "";
  const selected = source.slice(range.from, range.to); const at = token ? value.indexOf(token) : -1;
  if (at >= 0 && selected) value = value.slice(0, at) + selected + value.slice(at + token.length);
  const text = source.slice(0, range.from) + value + source.slice(range.to);
  return { text, selection: at >= 0 ? { from: range.from + at, to: range.from + at + (selected || token).length } : { from: range.from + value.length, to: range.from + value.length } };
}
