import type { DiagnosticPresentation, UiMessage } from "../../i18n/uiMessage";
import { parseFrontMatter, type FrontMatterField } from "./frontMatter";

export const MAX_METADATA_CHECK_BYTES = 256 * 1024;

export interface MetadataDiagnostic {
  id: string;
  field: FrontMatterField;
  title: string;
  message: string;
  presentation?: DiagnosticPresentation;
  severity: "warning" | "suggestion" | "information";
  readOnly?: boolean;
}

export interface MetadataDiagnosticReport {
  issues: MetadataDiagnostic[];
  checkedBytes: number;
  limited: boolean;
}

function issue(id: string, field: FrontMatterField, title: string, message: string, severity: MetadataDiagnostic["severity"], readOnly = false, messagePresentation?: UiMessage): MetadataDiagnostic {
  return { id, field, title, message, severity, readOnly, presentation: { title: { source: title }, message: messagePresentation ?? { source: message } } };
}

/** Local, syntax-only metadata guidance. It neither builds a site nor reads a cover URL. */
export function getMetadataDiagnostics(value: string): MetadataDiagnosticReport {
  if (value.length > MAX_METADATA_CHECK_BYTES) {
    return {
      checkedBytes: 0,
      limited: true,
      issues: [issue("metadata-size-limit", "title", "文稿超出本地检查上限", `为保持检查有界，本次只允许检查不超过 ${MAX_METADATA_CHECK_BYTES / 1024} KiB 的文稿。未执行 SEO、构建或网络校验。`, "information", true, { source: "为保持检查有界，本次只允许检查不超过 {limit} KiB 的文稿。未执行 SEO、构建或网络校验。", parameters: { limit: MAX_METADATA_CHECK_BYTES / 1024 } })],
    };
  }
  const checkedBytes = new TextEncoder().encode(value).byteLength;
  if (checkedBytes > MAX_METADATA_CHECK_BYTES) return {
    checkedBytes: 0,
    limited: true,
    issues: [issue("metadata-size-limit", "title", "文稿超出本地检查上限", `为保持检查有界，本次只允许检查不超过 ${MAX_METADATA_CHECK_BYTES / 1024} KiB 的文稿。未执行 SEO、构建或网络校验。`, "information", true, { source: "为保持检查有界，本次只允许检查不超过 {limit} KiB 的文稿。未执行 SEO、构建或网络校验。", parameters: { limit: MAX_METADATA_CHECK_BYTES / 1024 } })],
  };

  try {
    const snapshot = parseFrontMatter(value);
    if (!snapshot) return {
      checkedBytes,
      limited: false,
      issues: [issue("front-matter-missing", "title", "缺少 Front Matter", "可添加基础属性后填写标题、摘要和可选的 slug、固定链接、封面路径。检查不会自动创建属性。", "warning")],
    };
    if (snapshot.issue) return {
      checkedBytes,
      limited: false,
      issues: [issue("front-matter-structure", "title", "Front Matter 结构需要修复", `${snapshot.issue}。请在编辑器中直接修复原始 Front Matter；本地检查不会改写它。`, "warning", true, { source: "{issue}。请在编辑器中直接修复原始 Front Matter；本地检查不会改写它。", ...(snapshot.issuePresentation ? { labels: { issue: snapshot.issuePresentation } } : { parameters: { issue: snapshot.issue } }) })],
    };

    const { title, description, slug, permalink, cover } = snapshot.values;
    const issues: MetadataDiagnostic[] = [];
    if (!title.trim()) issues.push(issue("title-missing", "title", "缺少标题", "标题为空。请提供面向读者的文章标题。", "warning"));
    else if (Array.from(title.trim()).length < 20 || Array.from(title.trim()).length > 60) issues.push(issue("title-length", "title", "标题长度建议", `当前 ${Array.from(title.trim()).length} 个字符；编辑时可参考约 20–60 个字符，实际搜索展示会随平台、语言和站点而异。`, "suggestion", false, { source: "当前 {count} 个字符；编辑时可参考约 20–60 个字符，实际搜索展示会随平台、语言和站点而异。", parameters: { count: Array.from(title.trim()).length } }));
    if (!description.trim()) issues.push(issue("description-missing", "description", "缺少摘要", "摘要为空。请提供简短的文章说明。", "warning"));
    else if (Array.from(description.trim()).length < 50 || Array.from(description.trim()).length > 160) issues.push(issue("description-length", "description", "摘要长度建议", `当前 ${Array.from(description.trim()).length} 个字符；编辑时可参考约 50–160 个字符，实际搜索展示会随平台、语言和站点而异。`, "suggestion", false, { source: "当前 {count} 个字符；编辑时可参考约 50–160 个字符，实际搜索展示会随平台、语言和站点而异。", parameters: { count: Array.from(description.trim()).length } }));
    if (slug && !/^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(slug)) issues.push(issue("slug-syntax", "slug", "Slug 格式建议", "仅按本地语法建议：使用小写字母、数字和连字符，避免空格或重复连字符。", "suggestion"));
    if (permalink && (!permalink.startsWith("/") || /[\s?#]/.test(permalink))) issues.push(issue("permalink-syntax", "permalink", "固定链接格式建议", "仅按本地语法建议：使用以 / 开头且不含空白、? 或 # 的站内路径；具体路由仍取决于站点配置。", "suggestion"));
    if (cover && (/^[\s]|[\s]$/.test(cover) || /[\r\n]/.test(cover))) issues.push(issue("cover-syntax", "cover", "封面路径格式建议", "仅检查文本格式：封面路径不应包含首尾空白或换行。本检查不会下载、读取或验证封面。", "suggestion"));
    return { issues, checkedBytes, limited: false };
  } catch {
    return {
      checkedBytes,
      limited: false,
      issues: [issue("metadata-parser-failure", "title", "无法读取 Front Matter", "本地结构读取失败。请直接检查 Front Matter 原文；本检查没有修改文稿。", "warning", true)],
    };
  }
}
