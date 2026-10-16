import type { TextRange } from "../features/writing/markdownWriting";
import type { MarkdownSSGComponentKind, MarkdownSSGComponentOccurrence } from "../features/writing/markdownSSGComponents";
import { useI18n } from "../i18n/i18n";
import { ssgComponentMessages } from "../i18n/ssgComponentMessages";
import "./MarkdownSSGComponentStrip.css";

export interface MarkdownSSGComponentStripProps {
  occurrences: MarkdownSSGComponentOccurrence[];
  disabled?: boolean;
  onSelect: (range: TextRange, status?: string) => void;
}

const labelKeys: Record<MarkdownSSGComponentKind, string> = {
  callout: "提示框", lead: "导语", youtube: "YouTube", bilibili: "B 站", githubCard: "GitHub", figure: "图片", custom: "短代码",
};

const symbols: Record<MarkdownSSGComponentKind, string> = {
  callout: "!", lead: "¶", youtube: "▶", bilibili: "▷", githubCard: "<>", figure: "▧", custom: "{}",
};

export function MarkdownSSGComponentStrip({ occurrences, disabled = false, onSelect }: MarkdownSSGComponentStripProps) {
  const { t } = useI18n(ssgComponentMessages);
  const visible = occurrences.slice(0, 12);
  if (!visible.length) return null;
  return <section className="markdown-ssg-components" aria-label={t("文章 SSG 组件")}>
    <div className="markdown-ssg-components__heading"><span>{t("文章组件")}</span><span>{occurrences.length > visible.length ? t("显示前 {visible} 个，共 {total} 个", { visible: visible.length, total: occurrences.length }) : t("{count} 个", { count: occurrences.length })}</span></div>
    <div className="markdown-ssg-components__list" role="list">
      {visible.map((item) => <div key={item.id} role="listitem">
        <button
        className={`markdown-ssg-components__card markdown-ssg-components__card--${item.kind}`}
        type="button"
        disabled={disabled}
        onClick={() => onSelect(item.sourceRange, t("已定位到第 {line} 行的{kind}组件。", { line: item.lineNumber, kind: t(labelKeys[item.kind]) }))}
        aria-label={t("定位到第 {line} 行的{kind}组件：{title}", { line: item.lineNumber, kind: t(labelKeys[item.kind]), title: item.title })}
      >
        <span className="markdown-ssg-components__type" aria-hidden="true"><b>{symbols[item.kind]}</b>{t(labelKeys[item.kind])}</span>
        <strong>{item.title}</strong>
        <span className="markdown-ssg-components__preview">{item.previewText}</span>
        <span className="markdown-ssg-components__line">{t("第 {line} 行", { line: item.lineNumber })}</span>
        </button>
      </div>)}
    </div>
  </section>;
}
