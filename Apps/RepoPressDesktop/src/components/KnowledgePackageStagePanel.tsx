import { useEffect, useRef, useState } from "react";
import { KNOWLEDGE_PACKAGE_CHECK_EXCLUSIONS, KNOWLEDGE_PACKAGE_CHECK_LIMITS, type KnowledgePackageCheckReport } from "../contracts/knowledgePackageCheck";
import { KNOWLEDGE_PACKAGE_STAGE_LIMITS, type KnowledgePackageStageGateway, type KnowledgePackageStagePlan, type KnowledgePackageStageResult } from "../contracts/knowledgePackageStage";
import { useI18n } from "../i18n/i18n";
import { knowledgeStageMessages } from "../i18n/knowledgeStageMessages";

export interface KnowledgePackageStagePanelProps { gateway: KnowledgePackageStageGateway; enabled: boolean; disabled?: boolean; refreshKey?: number; }

const TTL = 300_000;
const MAX_TIME = 8.64e15;
const uuid = (v: unknown): v is string => typeof v === "string" && /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(v);
const sha = (v: unknown): v is string => typeof v === "string" && /^[0-9a-f]{64}$/.test(v);
const safeInt = (v: unknown): v is number => typeof v === "number" && Number.isSafeInteger(v) && v >= 0;
const time = (v: unknown): v is number => safeInt(v) && v > 0 && v <= MAX_TIME;
const path = (v: unknown): v is string => {
  if (typeof v !== "string" || !v.startsWith("/") || v.includes("\0") || new TextEncoder().encode(v).byteLength > 4000) return false;
  if (v === "/") return true;
  return !v.endsWith("/") && !v.includes("//") && v.slice(1).split("/").every((part) => part !== "" && part !== "." && part !== "..");
};
const sourcePath = (v: unknown): v is string => typeof v === "string" && new TextEncoder().encode(v).byteLength <= 4096 && v.startsWith("/") && v.endsWith(".json") && !v.includes("\0") && !v.includes("//") && v.slice(1).split("/").every((part) => part !== "" && part !== "." && part !== "..");
const candidatePath = (v: unknown): v is string => typeof v === "string" && new TextEncoder().encode(v).byteLength <= 4096 && v.startsWith("/") && !v.includes("\0") && !v.endsWith("/") && !v.includes("//") && v.slice(1).split("/").every((part) => part !== "" && part !== "." && part !== "..");
const exactKeys = (value: object, keys: string[]) => { const actual = Object.keys(value); return actual.length === keys.length && keys.every((key) => actual.includes(key)); };
const exactLimits = (v: unknown): v is typeof KNOWLEDGE_PACKAGE_CHECK_LIMITS => {
  if (!v || typeof v !== "object") return false;
  const x = v as Record<string, unknown>; const keys = ["manifestBytes", "resourceFiles", "resourceBytes", "packageBytes", "durationMs", "jsonNodes"];
  return Object.keys(x).length === keys.length && keys.every((key) => x[key] === KNOWLEDGE_PACKAGE_CHECK_LIMITS[key as keyof typeof KNOWLEDGE_PACKAGE_CHECK_LIMITS]);
};
const exactStageLimits = (v: unknown): v is typeof KNOWLEDGE_PACKAGE_STAGE_LIMITS => {
  if (!v || typeof v !== "object") return false;
  const x = v as Record<string, unknown>; const keys = ["candidateFiles", "candidateBytes", "durationMs"];
  return Object.keys(x).length === keys.length && keys.every((key) => x[key] === KNOWLEDGE_PACKAGE_STAGE_LIMITS[key as keyof typeof KNOWLEDGE_PACKAGE_STAGE_LIMITS]);
};
const exactExclusions = (v: unknown): boolean => Array.isArray(v) && v.length === KNOWLEDGE_PACKAGE_CHECK_EXCLUSIONS.length && new Set(v).size === v.length && KNOWLEDGE_PACKAGE_CHECK_EXCLUSIONS.every((x) => v.includes(x));
const reportKeys = ["reportId", "sourcePath", "format", "schemaVersion", "sourceManifestSchemaVersion", "scope", "itemCount", "revisionCount", "bodyFileCount", "archiveFileCount", "resourceByteSize", "byteSize", "sha256", "manifestSha256", "exclusions", "limits", "structureVerified", "contentVerified", "allSavedReferencesIncluded", "sourceManifestHashVerified", "consistentSnapshot", "includesCredentialStores", "includesCompletedOperations", "externalReferencesIncluded", "filesystemWrites", "currentLibraryChanged", "restoreReady", "checkedAtEpochMs", "expiresAtEpochMs"];
function validReport(value: unknown, source: string, now = Date.now()): value is KnowledgePackageCheckReport {
  if (!value || typeof value !== "object" || !exactKeys(value, reportKeys)) return false;
  const x = value as KnowledgePackageCheckReport; const files = x.bodyFileCount + x.archiveFileCount;
  return uuid(x.reportId) && x.sourcePath === source && sourcePath(x.sourcePath) && x.format === "repopress-knowledge-saved-files" && x.schemaVersion === 1 && x.sourceManifestSchemaVersion === 4 && x.scope === "selectedKnowledgePackage"
    && safeInt(x.itemCount) && x.itemCount <= 2000 && safeInt(x.revisionCount) && x.revisionCount <= x.itemCount * 32 && (x.itemCount === 0 ? x.revisionCount === 0 : x.revisionCount >= x.itemCount)
    && safeInt(x.bodyFileCount) && safeInt(x.archiveFileCount) && x.bodyFileCount <= x.revisionCount && x.archiveFileCount <= x.revisionCount && files <= KNOWLEDGE_PACKAGE_CHECK_LIMITS.resourceFiles && (x.itemCount === 0 ? x.bodyFileCount === 0 : x.bodyFileCount >= 1)
    && safeInt(x.resourceByteSize) && x.resourceByteSize <= KNOWLEDGE_PACKAGE_CHECK_LIMITS.resourceBytes && (files > 0 || x.resourceByteSize === 0) && safeInt(x.byteSize) && x.byteSize > 0 && x.byteSize >= x.resourceByteSize && x.byteSize <= KNOWLEDGE_PACKAGE_CHECK_LIMITS.packageBytes && sha(x.sha256) && sha(x.manifestSha256)
    && exactExclusions(x.exclusions) && exactLimits(x.limits) && x.structureVerified === true && x.contentVerified === true && x.allSavedReferencesIncluded === true && x.sourceManifestHashVerified === false && x.consistentSnapshot === false && x.includesCredentialStores === false && x.includesCompletedOperations === false && x.externalReferencesIncluded === false && x.filesystemWrites === false && x.currentLibraryChanged === false && x.restoreReady === false
    && time(x.checkedAtEpochMs) && time(x.expiresAtEpochMs) && x.checkedAtEpochMs <= now && x.expiresAtEpochMs > now && x.expiresAtEpochMs - x.checkedAtEpochMs === TTL;
}
const planKeys = ["planId", "sourcePath", "parentPath", "candidatePath", "format", "schemaVersion", "package", "candidateFileCount", "candidateByteSize", "candidateInventorySha256", "limits", "requiresSensitivePlaintextConsent", "candidateOnly", "currentLibraryChanged", "restoreReady", "createdAtEpochMs", "expiresAtEpochMs"];
function validPlan(value: unknown, source: string, parent: string, now = Date.now()): value is KnowledgePackageStagePlan {
  if (!value || typeof value !== "object" || !exactKeys(value, planKeys)) return false;
  const x = value as KnowledgePackageStagePlan; const expected = `${parent === "/" ? "" : parent}/repopress-knowledge-stage-${x.planId}`;
  return uuid(x.planId) && sourcePath(source) && path(parent) && x.sourcePath === source && x.parentPath === parent && x.candidatePath === expected && candidatePath(x.candidatePath) && x.format === "repopress-knowledge-isolated-candidate" && x.schemaVersion === 1
    && validReport(x.package, source, now) && x.package.reportId === x.planId && x.package.checkedAtEpochMs === x.createdAtEpochMs && x.package.expiresAtEpochMs === x.expiresAtEpochMs && safeInt(x.candidateFileCount) && x.candidateFileCount === x.package.bodyFileCount + x.package.archiveFileCount + 2 && x.candidateFileCount <= KNOWLEDGE_PACKAGE_STAGE_LIMITS.candidateFiles
    && safeInt(x.candidateByteSize) && x.candidateByteSize > x.package.resourceByteSize && x.candidateByteSize <= KNOWLEDGE_PACKAGE_STAGE_LIMITS.candidateBytes && sha(x.candidateInventorySha256) && exactStageLimits(x.limits)
    && x.requiresSensitivePlaintextConsent === true && x.candidateOnly === true && x.currentLibraryChanged === false && x.restoreReady === false && time(x.createdAtEpochMs) && time(x.expiresAtEpochMs) && x.createdAtEpochMs <= now && x.expiresAtEpochMs > now && x.expiresAtEpochMs - x.createdAtEpochMs === TTL;
}
const resultKeys = ["planId", "sourcePath", "candidatePath", "packageSha256", "manifestSha256", "candidateFileCount", "candidateByteSize", "candidateInventorySha256", "privatePermissionsVerified", "contentsVerified", "sourceRevalidated", "candidateOnly", "currentLibraryChanged", "restoreReady"];
function validResult(value: unknown, plan: KnowledgePackageStagePlan): value is KnowledgePackageStageResult {
  if (!value || typeof value !== "object" || !exactKeys(value, resultKeys)) return false;
  const x = value as KnowledgePackageStageResult;
  return uuid(x.planId) && x.planId === plan.planId && x.sourcePath === plan.sourcePath && x.candidatePath === plan.candidatePath && sha(x.packageSha256) && x.packageSha256 === plan.package.sha256 && sha(x.manifestSha256) && x.manifestSha256 === plan.package.manifestSha256 && safeInt(x.candidateFileCount) && x.candidateFileCount === plan.candidateFileCount && safeInt(x.candidateByteSize) && x.candidateByteSize === plan.candidateByteSize && sha(x.candidateInventorySha256) && x.candidateInventorySha256 === plan.candidateInventorySha256 && x.privatePermissionsVerified === true && x.contentsVerified === true && x.sourceRevalidated === true && x.candidateOnly === true && x.currentLibraryChanged === false && x.restoreReady === false;
}

export function KnowledgePackageStagePanel({ gateway, enabled, disabled = false, refreshKey }: KnowledgePackageStagePanelProps) {
  const { locale, t } = useI18n(knowledgeStageMessages);
  const usable = enabled && !disabled;
  const [source, setSource] = useState<string | null>(null); const [parent, setParent] = useState<string | null>(null); const [plan, setPlan] = useState<KnowledgePackageStagePlan | null>(null); const [consent, setConsent] = useState(false); const [result, setResult] = useState<KnowledgePackageStageResult | null>(null); const [busy, setBusy] = useState<"source" | "parent" | "planning" | "executing" | null>(null); const [error, setError] = useState(""); const [candidateError, setCandidateError] = useState<string | null>(null);
  const contextRef = useRef({ gateway, enabled, disabled, refreshKey, source: null as string | null, parent: null as string | null }); contextRef.current = { gateway, enabled, disabled, refreshKey, source, parent };
  const sourceRef = useRef(source); sourceRef.current = source; const parentRef = useRef(parent); parentRef.current = parent;
  const generation = useRef(0); const busyRef = useRef(false); const planRef = useRef<KnowledgePackageStagePlan | null>(null); const bindingRef = useRef<typeof contextRef.current | null>(null); const consentRef = useRef(false);
  const same = (c: typeof contextRef.current) => { const x = contextRef.current; return x.gateway === c.gateway && x.enabled === c.enabled && x.disabled === c.disabled && x.refreshKey === c.refreshKey && x.source === c.source && x.parent === c.parent; };
  const discard = (p: KnowledgePackageStagePlan | null, g: KnowledgePackageStageGateway | undefined) => { if (p && g) void g.discardKnowledgePackageStage(p.planId).catch(() => undefined); };
  const clear = () => { const p = planRef.current; discard(p, bindingRef.current?.gateway); planRef.current = null; bindingRef.current = null; consentRef.current = false; generation.current += 1; setPlan(null); setConsent(false); setResult(null); setCandidateError(null); setError(""); };
  useEffect(() => { clear(); busyRef.current = false; setSource(null); setParent(null); setBusy(null); return () => { discard(planRef.current, bindingRef.current?.gateway); planRef.current = null; bindingRef.current = null; generation.current += 1; busyRef.current = false; }; }, [gateway, enabled, disabled, refreshKey]);
  const current = usable && planRef.current === plan && bindingRef.current && same(bindingRef.current) && validPlan(plan, source ?? "", parent ?? "") ? plan : null;
  useEffect(() => { if (!current) return; const timer = window.setTimeout(() => { if (planRef.current !== current) return; discard(current, bindingRef.current?.gateway); planRef.current = null; bindingRef.current = null; consentRef.current = false; setPlan(null); setConsent(false); setError("计划已过期，请重新生成。"); }, Math.max(0, current.expiresAtEpochMs - Date.now())); return () => window.clearTimeout(timer); }, [current?.planId, current?.expiresAtEpochMs]);
  async function choose(kind: "source" | "parent") { const live = contextRef.current; if (!live.enabled || live.disabled || live.gateway !== gateway || busyRef.current) return; clear(); const ctx = { ...contextRef.current }; const activeGateway = ctx.gateway; const request = ++generation.current; busyRef.current = true; setBusy(kind); const shellSame = () => { const x = contextRef.current; return x.gateway === ctx.gateway && x.enabled === ctx.enabled && x.disabled === ctx.disabled && x.refreshKey === ctx.refreshKey; }; try { const next = kind === "source" ? await activeGateway.selectKnowledgePackageStageSource() : await activeGateway.selectKnowledgePackageStageParent(); if (request !== generation.current || !same(ctx) || !contextRef.current.enabled || contextRef.current.disabled) return; if (next !== null && (kind === "source" ? !sourcePath(next) : !path(next))) throw new Error("invalid"); if (next !== null) { if (kind === "source") { contextRef.current.source = next; setSource(next); } else { contextRef.current.parent = next; setParent(next); } } } catch { if (request === generation.current && shellSame()) setError(kind === "source" ? "无法选择资料 JSON 文件，请重新选择。" : "无法选择候选文件夹，请重新选择。"); } finally { if (request === generation.current && shellSame()) { busyRef.current = false; setBusy(null); } } }
  async function makePlan() { const s = source; const p = parent; const live = contextRef.current; const ctx = { ...live }; if (!live.enabled || live.disabled || live.gateway !== gateway || busyRef.current || !s || !p || !sourcePath(s) || !path(p) || ctx.source !== s || ctx.parent !== p || sourceRef.current !== s || parentRef.current !== p) return; clear(); const request = ++generation.current; const bound = { ...contextRef.current }; const activeGateway = bound.gateway; busyRef.current = true; setBusy("planning"); try { const next: unknown = await activeGateway.planKnowledgePackageStage(s, p); if (request !== generation.current || !same(bound) || !contextRef.current.enabled || contextRef.current.disabled || contextRef.current.gateway !== activeGateway || contextRef.current.source !== s || contextRef.current.parent !== p) { if (next && typeof next === "object" && uuid((next as Partial<KnowledgePackageStagePlan>).planId)) discard(next as KnowledgePackageStagePlan, bound.gateway); return; } if (!validPlan(next, s, p)) { if (next && typeof next === "object" && uuid((next as Partial<KnowledgePackageStagePlan>).planId)) discard(next as KnowledgePackageStagePlan, bound.gateway); throw new Error("invalid"); } planRef.current = next; bindingRef.current = bound; setPlan(next); } catch { if (request === generation.current && same(bound)) setError("无法生成候选预览；来源、清单、资源或固定限制不符合要求。"); } finally { if (request === generation.current && same(bound)) { busyRef.current = false; setBusy(null); } } }
  function toggleConsent(next: boolean) { const captured = current; const bound = bindingRef.current; const valid = captured !== null && captured === plan && captured === planRef.current && !!bound && bound === bindingRef.current && usable && !busyRef.current && busy === null && same(bound) && bound.gateway === contextRef.current.gateway && sourceRef.current === source && parentRef.current === parent && validPlan(captured, source ?? "", parent ?? "") && captured.expiresAtEpochMs > Date.now(); consentRef.current = valid && next; setConsent(valid && next); }
  async function execute() { const captured = current; const bound = bindingRef.current; if (!captured || captured !== plan || captured !== planRef.current || !bound || bound !== bindingRef.current || !usable || contextRef.current.gateway !== bound.gateway || busyRef.current || !consentRef.current || !same(bound) || sourceRef.current !== source || parentRef.current !== parent || captured.expiresAtEpochMs <= Date.now()) return; planRef.current = null; bindingRef.current = null; consentRef.current = false; setPlan(null); setConsent(false); setResult(null); setCandidateError(null); setError(""); const request = ++generation.current; busyRef.current = true; setBusy("executing"); try { const next: unknown = await bound.gateway.executeKnowledgePackageStage(captured.planId, true); if (request !== generation.current || !same(bound) || !validResult(next, captured)) throw new Error("invalid"); setResult(next); } catch { if (request === generation.current && same(bound)) { setError("候选副本结果未明；计划已消耗，不会自动重试。请检查候选文件夹。 "); setCandidateError(captured.candidatePath); } } finally { if (request === generation.current && same(bound)) { busyRef.current = false; setBusy(null); } } }
  return <section className="operation-plan" aria-label={t("资料候选副本")} aria-busy={busy !== null}>
    <h4>{t("资料候选副本")}</h4>
    <p className="publish-muted">{t("明确选择一个资料 JSON 文件和一个候选文件夹，生成新的隔离候选副本预览。预览只显示数量、大小、清单 SHA-256、来源和候选路径，不显示标题、来源 URL、正文或其他元数据。")}</p>
    <p className="publish-warning">{t("候选副本会保留敏感明文元数据；原始清单哈希无法复核，复制不是原子操作。候选文件夹权限为 700，文件为 600；不会安装、替换当前资料库或自动清理。")}</p>
    <button type="button" onClick={() => void choose("source")} disabled={!usable || busy !== null}>{t("选择资料 JSON 文件")}</button>
    {source && <p>{t("来源路径：{sourcePath}", { sourcePath: source })}</p>}
    <button type="button" onClick={() => void choose("parent")} disabled={!usable || busy !== null}>{t("选择候选文件夹")}</button>
    {parent && <p>{t("候选父文件夹：{parentPath}", { parentPath: parent })}</p>}
    {source && parent && <button type="button" onClick={() => void makePlan()} disabled={!usable || busy !== null}>{t("生成候选预览")}</button>}
    {busy === "source" && <p role="status">{t("正在选择资料 JSON 文件…")}</p>}
    {busy === "parent" && <p role="status">{t("正在选择候选文件夹…")}</p>}
    {busy === "planning" && <p role="status">{t("正在生成候选预览…")}</p>}
    {busy === "executing" && <p role="status">{t("正在创建并核验候选副本…")}</p>}
    {error && <p role="alert" className="publish-warning">{t(error)}{candidateError && t("候选路径：{candidatePath}", { candidatePath: candidateError })}</p>}
    {current && <div className="operation-plan">
      <p><strong>{t("候选预览（一次性，5 分钟内有效）")}</strong></p>
      <p>{t("候选路径：{candidatePath}", { candidatePath: current.candidatePath })}</p>
      <p>{t("资料项：{itemCount}；历史修订：{revisionCount}；文件：{candidateFileCount}；大小：{candidateByteSize} 字节", { itemCount: current.package.itemCount.toLocaleString(locale), revisionCount: current.package.revisionCount.toLocaleString(locale), candidateFileCount: current.candidateFileCount.toLocaleString(locale), candidateByteSize: current.candidateByteSize.toLocaleString(locale) })}</p>
      <p>{t("候选清单 SHA-256：{candidateInventorySha256}", { candidateInventorySha256: current.candidateInventorySha256 })}</p>
      <p>{t("包 SHA-256：{packageSha256}；包内清单 SHA-256：{manifestSha256}", { packageSha256: current.package.sha256, manifestSha256: current.package.manifestSha256 })}</p>
      <p>{t("检查时间：{checkedAt}；有效至：{expiresAt}", { checkedAt: new Date(current.createdAtEpochMs).toLocaleString(locale), expiresAt: new Date(current.expiresAtEpochMs).toLocaleString(locale) })}</p>
      <p>{t("固定范围：已选择资料；结构和内容已验证。当前资料库未改变，可恢复副本尚未生成。")}</p>
      <label htmlFor="knowledge-stage-sensitive-consent"><input id="knowledge-stage-sensitive-consent" type="checkbox" checked={consent} onChange={(event) => toggleConsent(event.target.checked)} disabled={busy !== null || !usable} />{t("我已知悉并同意创建敏感资料明文候选副本")}</label>
      <button type="button" onClick={() => void execute()} disabled={!usable || busy !== null || !consent}>{t("明确创建一次性候选副本")}</button>
      <button type="button" onClick={clear} disabled={busy !== null}>{t("取消候选计划")}</button>
    </div>}
    {result && <div role="status" className="operation-plan">
      <p><strong>{t("候选副本已创建并核验")}</strong></p>
      <p>{t("来源：{sourcePath}", { sourcePath: result.sourcePath })}</p>
      <p>{t("候选路径：{candidatePath}", { candidatePath: result.candidatePath })}</p>
      <p>{t("包 SHA-256：{packageSha256}；清单 SHA-256：{manifestSha256}", { packageSha256: result.packageSha256, manifestSha256: result.manifestSha256 })}</p>
      <p>{t("候选清单 SHA-256：{candidateInventorySha256}；文件：{candidateFileCount}；大小：{candidateByteSize} 字节", { candidateInventorySha256: result.candidateInventorySha256, candidateFileCount: result.candidateFileCount.toLocaleString(locale), candidateByteSize: result.candidateByteSize.toLocaleString(locale) })}</p>
      <p>{t("私有权限与内容已核验；当前资料库未改变，未生成可恢复副本。")}</p>
    </div>}
  </section>;
}
