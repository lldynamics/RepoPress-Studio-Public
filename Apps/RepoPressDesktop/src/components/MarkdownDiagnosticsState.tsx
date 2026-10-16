import type { MarkdownDiagnosticsSession } from "../features/writing/useMarkdownDiagnostics";
import { markdownDiagnosticStatusMessage } from "../features/writing/markdownDiagnosticStatus";
import { useI18n } from "../i18n/i18n";

export function MarkdownDiagnosticsState({ session }: { session: MarkdownDiagnosticsSession }) {
  const { t } = useI18n();
  if (session.status === "ready") return session.truncated
    ? <p role="status">{t("检查结果超过 500 项；仅保留前 500 项，处理后请重新检查。")}</p> : null;
  return <div className="markdown-diagnostics__state">
    <p role="status">{t(markdownDiagnosticStatusMessage(session.status))}</p>
    {session.status === "pending" && <button type="button" onClick={session.cancel}>{t("取消检查")}</button>}
    {["cancelled", "unavailable", "error"].includes(session.status) && <button type="button" onClick={session.retry}>{t("重新检查")}</button>}
  </div>;
}
