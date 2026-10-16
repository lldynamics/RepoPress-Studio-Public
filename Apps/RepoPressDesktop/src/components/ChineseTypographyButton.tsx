import { useState } from "react";
import type { TextRange } from "../features/writing/markdownWriting";
import { planChineseTypography, type ChineseTypographyPlan } from "../features/writing/chineseTypography";
import { useI18n } from "../i18n/i18n";
import { chineseTypographyMessages } from "../i18n/chineseTypographyMessages";
import "./ChineseTypographyButton.css";

export interface ChineseTypographyButtonProps {
  value: string;
  selection: TextRange;
  disabled?: boolean;
  onApply: (result: NonNullable<ChineseTypographyPlan>, status?: string) => void;
  className?: string;
}

function hasSelection(value: string, selection: TextRange): boolean {
  const from = Math.max(0, Math.min(value.length, selection.from));
  const to = Math.max(0, Math.min(value.length, selection.to));
  return from !== to;
}

/** Compact action for Chinese-Western typography cleanup in the Markdown editor. */
export function ChineseTypographyButton({ value, selection, disabled = false, onApply, className = "" }: ChineseTypographyButtonProps) {
  const { t } = useI18n(chineseTypographyMessages);
  const [status, setStatus] = useState<{ message: string; scope: string } | null>(null);
  const selected = hasSelection(value, selection);
  const scope = selected ? "选区" : "全文";
  const unavailable = disabled || value.length === 0;
  const title = t("整理{scope}中文与西文间距、标点和空白", { scope: t(scope) });

  function apply() {
    const result = planChineseTypography(value, selection);
    if (!result) { setStatus({ message: "{scope}无需调整", scope }); return; }
    setStatus({ message: "已整理{scope}中文排版", scope });
    onApply(result, t("已整理{scope}中文排版", { scope: t(scope) }));
  }

  return <span className={`chinese-typography-button ${className}`.trim()}>
    <button type="button" disabled={unavailable} onClick={apply} title={title} aria-label={title}>
      {t("中文排版")}<span aria-hidden="true">{t("（{scope}）", { scope: t(scope) })}</span>
    </button>
    <span className="chinese-typography-button__status" role="status" aria-live="polite">{status ? t(status.message, { scope: t(status.scope) }) : ""}</span>
  </span>;
}
