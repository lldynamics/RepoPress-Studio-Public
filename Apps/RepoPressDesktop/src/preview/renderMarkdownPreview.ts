import DOMPurify from "dompurify";
import { marked } from "marked";

const renderer = new marked.Renderer();
renderer.link = ({ text }) => "<a data-external-link=\"true\">" + text + "<span class=\"external-link-mark\" aria-label=\"外部链接，未直接打开\">↗</span></a>";
renderer.image = () => "<span class=\"blocked-resource\">[图片资源已阻止]</span>";

export function renderMarkdownPreview(markdown: string): string {
  const previewSource = markdown.replace(/^(?:\uFEFF)?(\+\+\+|---)[ \t]*\r?\n[\s\S]*?\r?\n\1[ \t]*(?:\r?\n|$)/, "");
  const parsed = marked.parse(previewSource, { async: false, renderer, gfm: true, breaks: false });
  const sanitized = DOMPurify.sanitize(parsed, {
    ALLOWED_TAGS: ["a", "blockquote", "br", "code", "del", "em", "h1", "h2", "h3", "h4", "h5", "h6", "hr", "li", "ol", "p", "pre", "span", "strong", "table", "tbody", "td", "th", "thead", "tr", "ul"],
    ALLOWED_ATTR: ["aria-label", "class", "data-external-link"],
    FORBID_ATTR: ["href", "src", "srcset", "style"],
  });
  return sanitized.replace(/javascript\s*:/gi, "");
}
