import { useEffect, useMemo, useRef, useState } from "react";
import type { ArticleStateContext, ArticleStateIssue, ArticleStateLocation, ArticleStateProjection } from "../contracts/articleState";
import type { ArticleStateChangePlan } from "../contracts/articleStateChange";
import { projectArticleState } from "../features/writing/articleState";
import { planArticleStateChange } from "../features/writing/articleStateChange";
import { useI18n } from "../i18n/i18n";
import { articleStateMessages } from "../i18n/articleStateMessages";
import "./ArticleStatePanel.css";

export interface ArticleStatePanelProps {
  value: string;
  context: ArticleStateContext;
  contextKey: string;
  active?: boolean;
  disabled?: boolean;
  compact?: boolean;
  onLocate?: (location: ArticleStateLocation, expectedText: string, expectedContextKey: string) => void;
  onApplyChange?: (plan: ArticleStateChangePlan) => Promise<boolean>;
}

const stateLabels: Record<NonNullable<ArticleStateProjection["state"]>, string> = { draft: "草稿", ready: "待发布", published: "已发布", localOnly: "仅本地" };
const issueLabels: Record<ArticleStateIssue["code"], string> = {
  frontMatterMissing: "缺少 Front Matter。", frontMatterInvalid: "Front Matter 无法解析。", draftMissing: "缺少 draft 字段。", titleMissing: "缺少标题。", dateMissing: "缺少日期。", dateInvalid: "日期无效。", dateTimezoneUnknown: "日期时区未核验。", dateFuture: "日期在未来。", outsideContentRoot: "文章在内容根目录之外。", siteUnknown: "站点未知。", invalidPath: "文章路径无效。", readOnly: "当前文件只读。", sizeLimit: "文章超过大小限制。", publicationUnverified: "线上发布仍未核验。", clockInvalid: "系统时间无效。",
};

function formatEpoch(epochMs: number, locale: string): string { return new Intl.DateTimeFormat(locale, { dateStyle: "medium", timeStyle: "short" }).format(epochMs); }
type ChangeTarget = ArticleStateChangePlan["target"];
const changeFailureMessages: Record<string, string> = { invalidTarget: "无法确认目标状态。", readOnly: "当前文件只读，无法申请变更。", notSiteArticle: "当前内容不属于站点文章。", sizeLimit: "文章超过大小限制，无法申请变更。", frontMatterMissing: "缺少 Front Matter，无法申请变更。", frontMatterInvalid: "Front Matter 无法解析，无法申请变更。", unchanged: "当前文章已经是该状态。" };

export function ArticleStatePanel({ value, context, contextKey, active = true, disabled = false, compact = false, onLocate, onApplyChange }: ArticleStatePanelProps) {
  const { locale, t } = useI18n(articleStateMessages);
  const [refreshToken, setRefreshToken] = useState(0);
  const [plan, setPlan] = useState<ArticleStateChangePlan | null>(null);
  const [planMessage, setPlanMessage] = useState<string | null>(null);
  const [applyMessage, setApplyMessage] = useState<string | null>(null);
  const [applying, setApplying] = useState(false);
  const applyingRef = useRef(false);
  const planHeadingRef = useRef<HTMLHeadingElement>(null);
  const planButtonRefs = useRef<Partial<Record<ChangeTarget, HTMLButtonElement | null>>>({});
  const mountedRef = useRef(true);
  const generationRef = useRef(0);
  const nowEpochMs = useMemo(() => active ? Date.now() : 0, [active, context, contextKey, refreshToken, value]);
  const projection = useMemo(() => active ? projectArticleState({ text: value, context, nowEpochMs }) : null, [active, context, contextKey, nowEpochMs, refreshToken, value]);
  useEffect(() => { mountedRef.current = true; return () => { mountedRef.current = false; }; }, []);
  useEffect(() => { generationRef.current += 1; setPlan(null); setPlanMessage(null); setApplyMessage(null); setApplying(false); }, [active, contextKey, disabled, value, refreshToken, compact]);
  useEffect(() => { if (plan && !applying) planHeadingRef.current?.focus(); }, [plan, applying]);
  if (!active || !projection) return null;
  const stateText = projection.state ? t(stateLabels[projection.state]) : t("状态待确认");
  const date = projection.date;
  const checkDate = projection.checkedAtEpochMs === null ? null : formatEpoch(projection.checkedAtEpochMs, locale);
  const locate = (issue: ArticleStateIssue) => { if (!disabled && issue.location && onLocate) onLocate(issue.location, value, contextKey); };
  const canChange = !compact && context.kind === "repository" && projection.scope === "site" && !projection.readOnly && !disabled && Boolean(onApplyChange);
  const structuralBlocked = projection.limited || projection.issues.some((issue) => issue.code === "frontMatterMissing" || issue.code === "frontMatterInvalid");
  const changeUnavailable = projection.limited ? "文章超过大小限制，无法申请变更。" : projection.issues.some((issue) => issue.code === "frontMatterMissing") ? "缺少 Front Matter，无法申请变更。" : projection.issues.some((issue) => issue.code === "frontMatterInvalid") ? "Front Matter 无法解析，无法申请变更。" : null;
  const currentTarget = (target: ChangeTarget) => projection.state === target;
  const planIsCurrent = Boolean(plan && plan.expectedText === value && plan.contextKey === contextKey && canChange);
  const requestChange = (target: ChangeTarget) => { if (!canChange || structuralBlocked || applying || currentTarget(target)) return; const generation = generationRef.current; const result = planArticleStateChange({ text: value, context, contextKey, nowEpochMs }, target); if (!mountedRef.current || generation !== generationRef.current) return; if (!result.ok) { setPlan(null); setPlanMessage(changeFailureMessages[result.reason] ?? "无法预览这次状态变更。"); return; } setPlanMessage(null); setApplyMessage(null); setPlan(result.plan); };
  const cancelPlan = () => { const target = plan?.target; setPlan(null); setPlanMessage(null); if (target) window.requestAnimationFrame(() => planButtonRefs.current[target]?.focus()); };
  const applyPlan = async () => { if (!planIsCurrent || !plan || !onApplyChange || applying || applyingRef.current) return; applyingRef.current = true; const consumedPlan = plan; const generation = generationRef.current; setPlan(null); setPlanMessage(null); setApplying(true); setApplyMessage(null); try { const ok = await onApplyChange(consumedPlan); if (!mountedRef.current || generation !== generationRef.current) return; setApplyMessage(ok ? "文章状态已应用到编辑器，尚未保存。" : "状态变更未应用，请重新预览。"); } catch { if (mountedRef.current && generation === generationRef.current) setApplyMessage("状态变更未应用，请重新预览。"); } finally { applyingRef.current = false; if (mountedRef.current && generation === generationRef.current) setApplying(false); } };
  const warnings = [...new Set((plan?.warnings ?? []).map((code) => t(issueLabels[code] ?? code)))];
  return <section className={`article-state-panel${compact ? " compact" : ""}`} aria-label={t("文章状态")}>
    <header><div className="article-state-heading"><h2>{t("文章状态")}</h2><span className="article-state-label">{stateText}</span>{(compact || !canChange) && <span className="article-state-readonly">{t("仅查看状态")}</span>}{projection.readOnly && <span className="article-state-readonly">{t("只读")}</span>}</div>{!compact && <div className="article-state-actions"><button type="button" onClick={() => { generationRef.current += 1; setPlan(null); setPlanMessage(null); setApplyMessage(null); setRefreshToken((token) => token + 1); }} disabled={disabled || applying}>{t("刷新文章状态")}</button></div>}</header>
    {compact ? <p className="article-state-meta">{projection.scope === "generalDraft" ? t("本机通用草稿，不属于任何站点。") : t("依据当前编辑内容")}</p> : <>
      <p className="article-state-meta">{projection.scope === "generalDraft" ? t("本机通用草稿，不属于任何站点。") : t("线上状态：未核验")} · {t("依据当前编辑内容")}</p>
      <p className="article-state-note">{t("待发布仅表示写作意图，线上状态仍需核验。")}</p>
      {date.value && <p className="article-state-date">{t("日期原文：{value}", { value: date.value })}{date.kind === "timezoneUnknown" && ` · ${t("日期没有时区，无法确认绝对时间。")}`}{date.kind === "future" && ` · ${t("日期在当前时间之后；这不会自动发布文章。")}`}</p>}
      {checkDate && <p className="article-state-date">{t("文章状态检查时间：{date}", { date: checkDate })}</p>}
      {projection.issues.length > 0 && <div className="article-state-issues" aria-label={t("文章状态")}>{projection.issues.map((issue, index) => <div className="article-state-issue" key={`${issue.code}-${index}`}><span>{t(issueLabels[issue.code])}</span>{issue.location && <button type="button" disabled={disabled || !onLocate} onClick={() => locate(issue)} aria-label={issue.location.kind === "site" ? t("查看站点：{issue}", { issue: t(issueLabels[issue.code]) }) : issue.location.kind === "publishing" ? t("查看发布证据：{issue}", { issue: t(issueLabels[issue.code]) }) : t("定位问题：{issue}", { issue: t(issueLabels[issue.code]) })}>{issue.location.kind === "site" ? t("查看站点") : issue.location.kind === "publishing" ? t("查看发布证据") : t("定位问题")}</button>}</div>)}</div>}
      {canChange && <div className="article-state-change-actions" aria-label={t("申请文章状态变更")}><button type="button" ref={(node) => { planButtonRefs.current.draft = node; }} disabled={applying || structuralBlocked || currentTarget("draft")} onClick={() => requestChange("draft")}>{t("预览设为草稿")}</button><button type="button" ref={(node) => { planButtonRefs.current.ready = node; }} disabled={applying || structuralBlocked || currentTarget("ready")} onClick={() => requestChange("ready")}>{t("预览设为待发布")}</button></div>}
      {canChange && changeUnavailable && <p className="article-state-change-message" role="status">{t(changeUnavailable)}</p>}
      {planMessage && <p className="article-state-change-message" role="status">{t(planMessage)}</p>}
      {applyMessage && <p className="article-state-change-message" role="status">{t(applyMessage)}</p>}
      {applying && <p className="article-state-change-message" role="status">{t("正在应用状态变更…")}</p>}
      {planIsCurrent && plan && <section className="article-state-change-preview" aria-label={t("文章状态变更预览")}><h3 tabIndex={-1} ref={planHeadingRef}>{t("文章状态变更预览")}</h3><p>{t("文稿：{path}", { path: context.kind === "repository" ? context.relativePath : "" })}</p><div className="article-state-change-field"><span>{t("变更前：")}</span><pre>{plan.beforeField === null ? t("draft（缺失）") : plan.beforeField}</pre></div><div className="article-state-change-field"><span>{t("变更后：")}</span><pre>{plan.afterField}</pre></div><p>{t("目标：{target}", { target: plan.target === "draft" ? t("草稿") : t("待发布") })}</p>{warnings.length > 0 && <ul className="article-state-change-warnings">{warnings.map((warning) => <li key={warning}>{warning}</li>)}</ul>}<p className="article-state-change-note">{t("只修改当前编辑内容，保存后才写入文件。")}</p><div className="article-state-change-actions"><button type="button" disabled={applying} onClick={() => void applyPlan()}>{t("确认应用到编辑器")}</button><button type="button" disabled={applying} onClick={cancelPlan}>{t("取消变更")}</button></div></section>}
    </>}
  </section>;
}

export default ArticleStatePanel;
