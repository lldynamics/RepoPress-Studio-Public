import { useEffect, useState } from "react";
import { getMetadataDiagnostics, type MetadataDiagnosticReport } from "../features/frontmatter/metadataDiagnostics";
import type { FrontMatterField } from "../features/frontmatter/frontMatter";
import { presentDiagnostic } from "../i18n/uiMessage";
import { useI18n } from "../i18n/i18n";
import "./MetadataInspector.css";

export interface MetadataInspectorProps {
  value: string;
  disabled?: boolean;
  onLocateField?: (field: FrontMatterField, expectedText: string) => void;
}

export function MetadataInspector({ value, disabled = false, onLocateField }: MetadataInspectorProps) {
  const { t } = useI18n();
  const [report, setReport] = useState<{ value: string; result: MetadataDiagnosticReport } | null>(null);
  const isCurrent = report?.value === value;
  useEffect(() => { setReport(null); }, [value]);

  return <section className="metadata-inspector" aria-label={t("Front Matter SEO 字段检查")}>
    <h2>{t("SEO 字段检查")}</h2>
    <p>{t("仅检查当前编辑内容中的 Front Matter 文本规则。它不等于完整 SEO、站点构建、发布或网络校验，也不会下载封面。")}</p>
    <button type="button" disabled={disabled} onClick={() => setReport({ value, result: getMetadataDiagnostics(value) })}>{t("生成本地报告")}</button>
    {isCurrent && report && <div className="metadata-inspector-report" role="status">
      {!report.result.issues.length && <p>{t("本次本地检查未发现常见字段建议。")}</p>}
      {!!report.result.issues.length && <ol>{report.result.issues.map((diagnostic) => <li key={diagnostic.id} className={`metadata-${diagnostic.severity}`}>
        <strong>{presentDiagnostic(diagnostic, t).title}</strong><p>{presentDiagnostic(diagnostic, t).message}</p>
        <button type="button" disabled={disabled || !onLocateField} onClick={() => onLocateField?.(diagnostic.field, report.value)}>{t("打开对应字段")}</button>
      </li>)}</ol>}
      {report.result.limited && <p>{t("结果已受检查上限限制，修改后请重新生成报告。")}</p>}
    </div>}
  </section>;
}
