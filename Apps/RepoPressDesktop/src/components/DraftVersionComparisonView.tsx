import { Fragment, useId, useMemo, useState } from "react";
import type { DraftComparisonSections } from "../features/writing/draftComparison";
import { foldDraftDiffLines } from "../features/writing/draftDiffRows";
import type { DraftDiffLine, DraftVersionComparison } from "../features/writing/draftHistory";
import { useI18n } from "../i18n/i18n";
import { draftHistoryMessages } from "../i18n/draftHistoryMessages";
import { draftComparisonMessages } from "../i18n/draftComparisonMessages";
import "./DraftVersionComparisonView.css";

const messages = { ...draftHistoryMessages, ...draftComparisonMessages };

export interface DraftVersionComparisonViewProps {
  comparison: DraftComparisonSections;
  targetKind: "current" | "version";
}

function DiffPre({ comparison, targetKind, label, ariaLabel, truncatedText, t }: {
  comparison: DraftVersionComparison;
  targetKind: DraftVersionComparisonViewProps["targetKind"];
  label: string;
  ariaLabel?: string;
  truncatedText: string;
  t: ReturnType<typeof useI18n>["t"];
}) {
  const targetHeader = targetKind === "current" ? t("+++ 当前稿") : t("+++ 对比版本");
  const resolvedAriaLabel = ariaLabel ?? (targetKind === "current" ? t("当前稿与所选版本的统一差异") : t("两个历史版本的统一差异"));
  const lines = comparison.truncated ? [] : comparison.lines;
  if (comparison.truncated) return <pre className="draft-version-comparison__pre" aria-label={resolvedAriaLabel} data-label={label} tabIndex={-1}>{truncatedText}</pre>;
  const header = [t("--- 历史版本"), targetHeader].join("\n");
  return <pre className="draft-version-comparison__pre" aria-label={resolvedAriaLabel} data-label={label} tabIndex={-1}>{header}{lines.length ? `\n` : ""}<DiffLines lines={lines} /></pre>;
}

function DiffLines({ lines }: { lines: readonly DraftDiffLine[] }) {
  return <>{lines.map((line, index) => <span key={`${line.kind}-${index}`} className={`draft-version-comparison__line draft-version-comparison__line--${line.kind}`}>
    {line.kind === "added" ? "+" : line.kind === "removed" ? "-" : " "}{line.text}{index < lines.length - 1 ? "\n" : ""}
  </span>)}</>;
}

function DiffRow({ line, t }: { line: DraftDiffLine; t: ReturnType<typeof useI18n>["t"] }) {
  const label = line.kind === "added"
    ? t("新增目标第 {line} 行：{text}", { line: line.currentLine ?? "", text: line.text })
    : line.kind === "removed"
      ? t("删除来源第 {line} 行：{text}", { line: line.historicalLine ?? "", text: line.text })
      : t("来源第 {source} 行，目标第 {target} 行：{text}", { source: line.historicalLine ?? "", target: line.currentLine ?? "", text: line.text });
  return <div role="row" className={`draft-version-comparison__row draft-version-comparison__line--${line.kind}`} aria-label={label}>
    <span role="cell" className="draft-version-comparison__number">{line.historicalLine}</span>
    <span role="cell" className="draft-version-comparison__number">{line.currentLine}</span>
    <span role="cell" className="draft-version-comparison__content"><span aria-hidden="true" className="draft-version-comparison__prefix">{line.kind === "added" ? "+" : line.kind === "removed" ? "-" : " "}</span><code className="draft-version-comparison__text">{line.text}</code></span>
  </div>;
}

function DiffTable({ comparison, owner, targetKind, label, t }: {
  comparison: DraftVersionComparison;
  owner: DraftComparisonSections;
  targetKind: DraftVersionComparisonViewProps["targetKind"];
  label: string;
  t: ReturnType<typeof useI18n>["t"];
}) {
  const id = useId();
  const rows = useMemo(() => foldDraftDiffLines(comparison.lines), [comparison.lines]);
  const folds = rows.filter(row => row.kind === "fold");
  const [expansion, setExpansion] = useState(() => ({ owner, ids: new Set<string>() }));
  // Guard during render so a new comparison never presents the previous pair's expansion.
  const expanded = expansion.owner === owner ? expansion.ids : new Set<string>();
  if (expansion.owner !== owner) setExpansion({ owner, ids: expanded });
  const setExpanded = (ids: Set<string>) => setExpansion({ owner, ids });
  const toggle = (foldId: string) => {
    const next = new Set(expanded);
    if (next.has(foldId)) next.delete(foldId); else next.add(foldId);
    setExpanded(next);
  };
  const ariaLabel = targetKind === "current" ? t("当前稿与所选版本的统一差异") : t("两个历史版本的统一差异");
  return <>
    <p className="draft-version-comparison__hint">{t("行号按当前分区计数。")}</p>
    {folds.length > 0 && <div className="draft-version-comparison__controls">
      <button type="button" disabled={folds.every(row => expanded.has(row.id))} onClick={() => setExpanded(new Set(folds.map(row => row.id)))}>{t("展开全部未变化内容")}</button>
      <button type="button" disabled={expanded.size === 0} onClick={() => setExpanded(new Set())}>{t("收起全部未变化内容")}</button>
    </div>}
    <div role="table" tabIndex={0} className="draft-version-comparison__table" aria-label={ariaLabel} data-label={label}>
      <div className="draft-version-comparison__table-content">
        <div role="rowgroup" className="draft-version-comparison__header-group"><div role="row" className="draft-version-comparison__row draft-version-comparison__header">
          <span role="columnheader">{t("来源行")}</span><span role="columnheader">{targetKind === "current" ? t("当前稿行") : t("对比版本行")}</span><span role="columnheader">{t("差异内容")}</span>
        </div></div>
        {rows.map(row => row.kind === "line" ? <div role="rowgroup" key={`line-${row.index}`}><DiffRow line={row.line} t={t} /></div> : <Fragment key={`fold-${row.id}`}>
          <div role="rowgroup"><div role="row" className="draft-version-comparison__fold"><div role="cell" aria-colspan={3}>
            <button type="button" aria-expanded={expanded.has(row.id)} aria-controls={`${id}-rows-${row.id}`} onClick={() => toggle(row.id)}>{expanded.has(row.id) ? t("收起 {count} 行未变化内容", { count: row.lines.length }) : t("展开 {count} 行未变化内容", { count: row.lines.length })}</button>
          </div></div></div>
          <div role="rowgroup" id={`${id}-rows-${row.id}`} hidden={!expanded.has(row.id)}>
            {expanded.has(row.id) && row.lines.map((line, index) => <DiffRow key={row.startIndex + index} line={line} t={t} />)}
          </div>
        </Fragment>)}
      </div>
    </div>
  </>;
}

function DiffSection({ heading, comparison, targetKind, headingId, t }: {
  heading: string;
  comparison: DraftVersionComparison | null;
  targetKind: DraftVersionComparisonViewProps["targetKind"];
  headingId: string;
  t: ReturnType<typeof useI18n>["t"];
}) {
  return <section className="draft-version-comparison__section" aria-labelledby={headingId}>
    <h3 id={headingId}>{heading}</h3>
    {comparison ? <DiffPre comparison={comparison} targetKind={targetKind} label={heading} ariaLabel={heading === t("Front Matter 原文差异") ? t("Front Matter 原文统一差异") : undefined} truncatedText={t("文稿超出比较上限，已仅显示统计信息。")} t={t} /> : <p className="draft-version-comparison__empty">{t("此比较没有 Front Matter。")} </p>}
  </section>;
}

export function DraftVersionComparisonView({ comparison, targetKind }: DraftVersionComparisonViewProps) {
  const { t } = useI18n(messages);
  const id = useId();
  const fullHeadingId = `${id}-full`;
  const frontMatterHeadingId = `${id}-front-matter`;
  const bodyHeadingId = `${id}-body`;
  const caption = `${t("+{added} 行 · −{removed} 行", { added: comparison.full.addedCount, removed: comparison.full.removedCount })}${comparison.full.truncated ? t(" · 已截断") : ""}`;

  if (comparison.fallback === "unclosedFrontMatter" || comparison.fallback === "comparisonLimit") {
    return <div className="draft-version-comparison draft-version-comparison--fallback">
      <p className="draft-version-comparison__caption">{caption}</p>
      <section className="draft-version-comparison__section" aria-labelledby={fullHeadingId}>
        <h3 id={fullHeadingId}>{t("全文差异")}</h3>
        {comparison.fallback === "unclosedFrontMatter" && <p className="draft-version-comparison__notice">{t("Front Matter 未闭合，无法安全拆分差异；以下显示全文差异。")}</p>}
        {comparison.full.truncated
          ? <DiffPre comparison={comparison.full} targetKind={targetKind} label={t("全文差异")} truncatedText={t("文稿超出比较上限，已仅显示统计信息。")} t={t} />
          : <DiffTable comparison={comparison.full} owner={comparison} targetKind={targetKind} label={t("全文差异")} t={t} />}
      </section>
    </div>;
  }

  return <div className="draft-version-comparison">
    <p className="draft-version-comparison__caption">{caption}</p>
    <DiffSection heading={t("Front Matter 原文差异")} comparison={comparison.frontMatter} targetKind={targetKind} headingId={frontMatterHeadingId} t={t} />
    {comparison.body && <section className="draft-version-comparison__section" aria-labelledby={bodyHeadingId}>
      <h3 id={bodyHeadingId}>{t("正文差异")}</h3>
      <DiffTable comparison={comparison.body} owner={comparison} targetKind={targetKind} label={t("正文差异")} t={t} />
    </section>}
  </div>;
}

export default DraftVersionComparisonView;
