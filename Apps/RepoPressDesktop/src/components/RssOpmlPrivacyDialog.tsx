import { useEffect, useRef, useState } from "react";
import type { RssGateway, RssOpmlDirection, RssOpmlReview } from "../features/rss/contracts";
import { useI18n } from "../i18n/i18n";
import { rssMessages } from "../i18n/rssMessages";

export interface RssOpmlPrivacyDialogProps {
  gateway: RssGateway;
  onClose: () => void;
  onChanged: () => Promise<void> | void;
}

export function RssOpmlPrivacyDialog({ gateway, onClose, onChanged }: RssOpmlPrivacyDialogProps) {
  const { t } = useI18n(rssMessages);
  const [direction, setDirection] = useState<RssOpmlDirection>("import");
  const [opml, setOpml] = useState("");
  const [review, setReview] = useState<RssOpmlReview | null>(null);
  const [output, setOutput] = useState("");
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState("");
  const [error, setError] = useState("");
  const generation = useRef(0);
  const stateGateway = useRef(gateway);
  const dialogRef = useRef<HTMLElement | null>(null);
  const closeRef = useRef<() => void>(() => undefined);

  useEffect(() => {
    generation.current += 1; stateGateway.current = gateway; setReview(null); setOutput(""); setMessage(""); setError(""); setBusy(false);
    return () => { generation.current += 1; };
  }, [gateway]);
  const close = () => { generation.current += 1; setBusy(false); onClose(); };
  closeRef.current = close;
  useEffect(() => {
    const previous = document.activeElement instanceof HTMLElement ? document.activeElement : null;
    dialogRef.current?.focus();
    const onKeyDown = (event: KeyboardEvent) => { if (event.key === "Escape") { event.preventDefault(); closeRef.current(); } };
    window.addEventListener("keydown", onKeyDown);
    return () => { window.removeEventListener("keydown", onKeyDown); previous?.focus(); };
  }, []);

  const gatewayChanged = stateGateway.current !== gateway;
  const visibleReview = gatewayChanged ? null : review;
  const visibleOutput = gatewayChanged ? "" : output;
  const visibleBusy = gatewayChanged ? false : busy;
  const visibleMessage = gatewayChanged ? "" : message;
  const visibleError = gatewayChanged ? "" : error;

  const changeDirection = (next: RssOpmlDirection) => {
    generation.current += 1;
    setDirection(next); setReview(null); setOutput(""); setMessage(""); setError(""); setBusy(false);
  };
  const changeOpml = (value: string) => {
    generation.current += 1;
    setOpml(value); setReview(null); setMessage(""); setError(""); setBusy(false);
  };
  const inspect = async () => {
    const sequence = ++generation.current;
    setBusy(true); setError(""); setMessage(""); setOutput("");
    try {
      const next = await gateway.reviewOpml({ direction, ...(direction === "import" ? { opml } : {}) });
      if (sequence !== generation.current) return;
      setReview(next);
    } catch (caught) {
      if (sequence === generation.current) setError(errorMessage(caught, t("OPML 操作失败，请重新审查。")));
    } finally {
      if (sequence === generation.current) setBusy(false);
    }
  };
  const execute = async (action: "redact" | "exclude") => {
    if (!visibleReview || gatewayChanged) return;
    const sequence = ++generation.current;
    const reviewedSource = opml;
    setBusy(true); setError(""); setMessage("");
    try {
      const result = await gateway.executeOpml({ direction, ...(direction === "import" ? { opml: reviewedSource } : {}), fingerprint: visibleReview.fingerprint, action });
      if (sequence !== generation.current) return;
      setReview(null);
      if (direction === "import") {
        setOpml("");
        setMessage(t("OPML 导入完成：新增 {importedCount}，跳过 {skippedCount}，排除 {excludedCount}。", { importedCount: result.importedCount, skippedCount: result.skippedCount, excludedCount: result.excludedCount }));
        if (result.importedCount > 0) await onChanged();
      } else {
        setOutput(result.opml ?? "");
        setMessage(t("安全 OPML 已生成：导出 {exportedCount}，排除 {excludedCount}。", { exportedCount: result.exportedCount, excludedCount: result.excludedCount }));
      }
    } catch (caught) {
      if (sequence === generation.current) setError(errorMessage(caught, t("OPML 操作失败，请重新审查。")));
    } finally {
      if (sequence === generation.current) setBusy(false);
    }
  };

  return <div className="rss-modal-backdrop" role="presentation">
    <section ref={dialogRef} tabIndex={-1} className="rss-modal rss-opml-privacy" role="dialog" aria-modal="true" aria-label={t("OPML 隐私审查")}>
      <header><h2>{t("OPML 隐私审查")}</h2><button type="button" onClick={close} aria-label={t("关闭")}>×</button></header>
      <div className="rss-segmented" role="group" aria-label={t("OPML 操作方向")}>
        <button type="button" aria-pressed={direction === "import"} onClick={() => changeDirection("import")}>{t("导入 OPML")}</button>
        <button type="button" aria-pressed={direction === "export"} onClick={() => changeDirection("export")}>{t("导出 OPML")}</button>
      </div>
      <p className="rss-help">{t("执行前会检查订阅地址中的常见凭据参数和用户信息；审查不会导入、导出或修改订阅。")}</p>
      <p className="rss-help">{t("检查只识别已知的敏感查询参数名，无法识别路径或自定义参数名中的秘密；RSS 备份不会经过此脱敏流程。")}</p>
      {direction === "import" && <label>{t("OPML 文本")}<textarea value={opml} onChange={(event) => changeOpml(event.target.value)} placeholder={t("粘贴 OPML XML")} rows={10} /></label>}
      <div className="rss-modal-actions"><button type="button" onClick={() => void inspect()} disabled={visibleBusy || (direction === "import" && !opml.trim())}>{visibleBusy ? t("正在审查…") : t("审查风险")}</button></div>
      {visibleReview && <section className="rss-opml-review" aria-label={t("OPML 风险审查结果")}>
        <h3>{t("审查结果")}</h3>
        <p>{t("共 {totalCount} 个订阅；{affectedCount} 个含风险地址，{blockedCount} 个不能安全脱敏。", { totalCount: visibleReview.totalCount, affectedCount: visibleReview.affectedCount, blockedCount: visibleReview.blockedCount })}</p>
        {visibleReview.findings.length ? <ul>{visibleReview.findings.map((finding, position) => <li key={`${finding.index}-${finding.location}-${position}`}><strong>{finding.location}</strong><span>{finding.displayUrl}</span><small>{finding.containsUserInfo ? t("含 URL 用户信息") : t("敏感参数：{names}", { names: finding.parameterNames.join(", ") })}</small></li>)}</ul> : <p>{t("未发现已知的地址凭据风险。")}</p>}
        <p className="rss-help">{t("必须选择脱敏或排除；不会保留审查出的原始风险地址。")}</p>
        <div className="rss-modal-actions">
          <button type="button" onClick={() => void execute("redact")} disabled={visibleBusy || visibleReview.blockedCount > 0}>{t("脱敏后执行")}</button>
          <button type="button" onClick={() => void execute("exclude")} disabled={visibleBusy}>{t("排除风险订阅后执行")}</button>
          <button type="button" onClick={() => { generation.current += 1; setReview(null); setBusy(false); }}>{t("取消审查")}</button>
        </div>
      </section>}
      {direction === "export" && visibleOutput && <label>{t("安全 OPML 文本")}<textarea value={visibleOutput} readOnly rows={10} /></label>}
      {visibleMessage && <p role="status">{visibleMessage}</p>}
      {visibleError && <p role="alert">{visibleError}</p>}
    </section>
  </div>;
}

function errorMessage(value: unknown, fallback: string) {
  const message = value instanceof Error ? value.message : value && typeof value === "object" && "message" in value && typeof value.message === "string" ? value.message : "";
  return message.trim().slice(0, 500) || fallback;
}
