import { useEffect, useRef, useState } from "react";
import type { KnowledgeRestoreStrategy } from "../contracts/knowledgeRestoreQualification";
import { KNOWLEDGE_MERGE_PROJECTION_LIMITS, type KnowledgeMergeProjectionGateway, type KnowledgeMergeProjectionPlan, type KnowledgeMergeProjectionReceipt } from "../contracts/knowledgeMergeProjection";
import { validKnowledgeRestoreQualificationPlan } from "./KnowledgeRestoreQualificationPanel";

export interface KnowledgeMergeProjectionPanelProps { gateway: KnowledgeMergeProjectionGateway; enabled: boolean; disabled?: boolean; refreshKey?: number; }
const strategies: KnowledgeRestoreStrategy[] = ["requireNoIdentityConflicts", "keepCurrentIdentities"];
const planKeys = ["schemaVersion", "scope", "planId", "source", "projection", "limits", "privacyMode", "privacyResetAcknowledgementRequired", "currentPermissionsPreserved", "sourcePermissionsCopied", "projectedManifestValidated", "filesystemWrites", "currentLibraryChanged", "restoreReady", "consistentSnapshot", "checkedAtEpochMs", "expiresAtEpochMs"] as const;
const projectionKeys = ["state", "reason", "manifestSha256", "manifestByteSize", "itemCount", "revisionCount", "folderCount", "fileCount", "resourceByteSize", "bodyByteSize", "archiveByteSize", "importedItems", "importedFolders", "resetPermissionItems", "completedOperationsExcluded"] as const;
const receiptKeys = ["planId", "projectionManifestSha256", "itemCount", "revisionCount", "folderCount", "importedItems", "importedFolders", "resetPermissionItems", "privacyResetAcknowledged", "importedPermissionsDisabled", "currentPermissionsPreserved", "sourcePermissionsCopied", "validatedInMemory", "filesystemWrites", "currentLibraryChanged", "restoreReady", "consistentSnapshot", "completedAtEpochMs"] as const;
const exact = (v: unknown, keys: readonly string[]) => !!v && typeof v === "object" && Object.keys(v as object).length === keys.length && keys.every((k) => Object.prototype.hasOwnProperty.call(v as object, k));
const integer = (v: unknown): v is number => typeof v === "number" && Number.isSafeInteger(v) && v >= 0;
const time = (v: unknown): v is number => integer(v) && v > 0 && v <= 8.64e15;
const sha = (v: unknown): v is string => typeof v === "string" && /^[0-9a-f]{64}$/.test(v);
const uuid = (v: unknown): v is string => typeof v === "string" && /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(v);
const path = (v: unknown): v is string => typeof v === "string" && v.startsWith("/") && new TextEncoder().encode(v).byteLength <= 4096 && !v.includes("\0") && v !== "/" && !v.endsWith("/") && !v.includes("//") && v.slice(1).split("/").every((p) => p !== "." && p !== "..");
const candidatePath = (v: unknown) => path(v) && /^repopress-knowledge-stage-[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(v.slice(v.lastIndexOf("/") + 1));
const limitsValid = (v: unknown) => !!v && exact(v, Object.keys(KNOWLEDGE_MERGE_PROJECTION_LIMITS)) && Object.keys(KNOWLEDGE_MERGE_PROJECTION_LIMITS).every((k) => (v as Record<string, unknown>)[k] === KNOWLEDGE_MERGE_PROJECTION_LIMITS[k as keyof typeof KNOWLEDGE_MERGE_PROJECTION_LIMITS]);
const nullProjection = (p: KnowledgeMergeProjectionPlan["projection"]) => [p.manifestSha256, p.manifestByteSize, p.itemCount, p.revisionCount, p.folderCount, p.fileCount, p.resourceByteSize, p.bodyByteSize, p.archiveByteSize, p.importedItems, p.importedFolders, p.resetPermissionItems].every((v) => v === null);
export function validKnowledgeMergeProjectionPlan(value: unknown, selectedPath: string, strategy: KnowledgeRestoreStrategy, now = Date.now()): value is KnowledgeMergeProjectionPlan {
  if (!exact(value, planKeys))
    return false;
  const x = value as KnowledgeMergeProjectionPlan;
  const p = x.projection;
  const s = x.source;
  if (!uuid(x.planId)
    || x.schemaVersion !== 1
    || x.scope !== "knowledgeMergeProjection"
    || !validKnowledgeRestoreQualificationPlan(s, selectedPath, strategy, now)
    || !exact(p, projectionKeys)
    || !limitsValid(x.limits)
    || x.privacyMode !== "disableImportedPermissions"
    || x.privacyResetAcknowledgementRequired !== true
    || x.currentPermissionsPreserved !== true
    || x.sourcePermissionsCopied !== false
    || x.filesystemWrites !== false
    || x.currentLibraryChanged !== false
    || x.restoreReady !== false
    || x.consistentSnapshot !== false
    || !time(x.checkedAtEpochMs)
    || !time(x.expiresAtEpochMs)
    || x.checkedAtEpochMs !== s.checkedAtEpochMs
    || x.expiresAtEpochMs !== s.expiresAtEpochMs
    || x.checkedAtEpochMs > now
    || x.expiresAtEpochMs <= now
    || x.expiresAtEpochMs - x.checkedAtEpochMs !== 300000
    || p.completedOperationsExcluded !== true
    || !["validated", "blocked"].includes(p.state)
    || !["none", "qualificationBlocked", "folderNameCollision", "capacityExceeded", "manifestInvalid", "referenceMismatch"].includes(p.reason))
    return false;
  if (s.qualification.state === "blocked") return p.state === "blocked"
    && p.reason === "qualificationBlocked"
    && x.projectedManifestValidated === false
    && nullProjection(p);
  if (p.state === "blocked") return p.reason !== "none"
    && p.reason !== "qualificationBlocked"
    && x.projectedManifestValidated === false
    && nullProjection(p);
  const q = s.qualification;
  const itemCount = (q.addItems ?? -1) + (q.retainItems ?? -1);
  const folderCount = (q.addFolders ?? -1) + (q.retainFolders ?? -1);
  return p.reason === "none"
    && x.projectedManifestValidated === true
    && sha(p.manifestSha256)
    && integer(p.manifestByteSize)
    && p.manifestByteSize > 0
    && p.manifestByteSize <= KNOWLEDGE_MERGE_PROJECTION_LIMITS.manifestBytes
    && p.itemCount === itemCount
    && p.itemCount <= KNOWLEDGE_MERGE_PROJECTION_LIMITS.items
    && integer(p.revisionCount)
    && p.revisionCount >= p.itemCount
    && p.revisionCount >= s.candidate.currentLibrary.revisionCount! + q.addItems!
    && p.revisionCount <= s.candidate.currentLibrary.revisionCount! + s.candidate.revisionCount
    && p.revisionCount <= p.itemCount * 32
    && p.folderCount === folderCount
    && p.folderCount <= KNOWLEDGE_MERGE_PROJECTION_LIMITS.folders
    && integer(p.fileCount)
    && (p.revisionCount === 0
      ? p.fileCount === 0 && p.resourceByteSize === 0
      : p.fileCount >= 1 && p.fileCount <= p.revisionCount * 2)
    && p.fileCount >= s.currentResources.fileCount!
    && p.fileCount <= KNOWLEDGE_MERGE_PROJECTION_LIMITS.resourceFiles
    && integer(p.resourceByteSize)
    && p.resourceByteSize === p.bodyByteSize! + p.archiveByteSize!
    && p.resourceByteSize >= s.currentResources.byteSize!
    && p.resourceByteSize <= KNOWLEDGE_MERGE_PROJECTION_LIMITS.resourceBytes
    && integer(p.bodyByteSize)
    && p.bodyByteSize <= KNOWLEDGE_MERGE_PROJECTION_LIMITS.bodyBytes
    && integer(p.archiveByteSize)
    && p.archiveByteSize <= KNOWLEDGE_MERGE_PROJECTION_LIMITS.archiveBytes
    && p.importedItems === q.addItems
    && p.importedFolders === q.addFolders
    && p.importedItems !== null
    && integer(p.resetPermissionItems)
    && p.resetPermissionItems <= p.importedItems;
}
function receiptValid(v: unknown, old: KnowledgeMergeProjectionPlan, now = Date.now()): v is KnowledgeMergeProjectionReceipt {
  if (!exact(v, receiptKeys))
    return false;
  const r = v as KnowledgeMergeProjectionReceipt;
  const p = old.projection;
  return uuid(r.planId)
    && r.planId === old.planId
    && sha(r.projectionManifestSha256)
    && r.projectionManifestSha256 === p.manifestSha256
    && r.itemCount === p.itemCount
    && r.revisionCount === p.revisionCount
    && r.folderCount === p.folderCount
    && r.importedItems === p.importedItems
    && r.importedFolders === p.importedFolders
    && r.resetPermissionItems === p.resetPermissionItems
    && r.privacyResetAcknowledged === true
    && r.importedPermissionsDisabled === true
    && r.currentPermissionsPreserved === true
    && r.sourcePermissionsCopied === false
    && r.validatedInMemory === true
    && r.filesystemWrites === false
    && r.currentLibraryChanged === false
    && r.restoreReady === false
    && r.consistentSnapshot === false
    && time(r.completedAtEpochMs)
    && r.completedAtEpochMs >= old.checkedAtEpochMs
    && r.completedAtEpochMs <= now
    && r.completedAtEpochMs < old.expiresAtEpochMs;
}
const recognizable = (v: unknown) => !!v && typeof v === "object" && uuid((v as Partial<KnowledgeMergeProjectionPlan>).planId);

const snapshot = (plan: KnowledgeMergeProjectionPlan) => JSON.stringify(planKeys.map(key => plan[key]));
const copy = <T,>(value: T): T => JSON.parse(JSON.stringify(value)) as T;
const strategyLabel = (value: KnowledgeRestoreStrategy) => value === "requireNoIdentityConflicts" ? "要求无身份冲突" : "保留当前数据";
const reasonLabel: Record<KnowledgeMergeProjectionPlan["projection"]["reason"], string> = {
  none: "校验通过", qualificationBlocked: "当前来源证据或身份策略不满足要求",
  folderNameCollision: "不同 ID 的分类名称重名", capacityExceeded: "合并后超出固定容量",
  manifestInvalid: "合并清单不满足资料库规则", referenceMismatch: "合并资源引用不匹配",
};

export function KnowledgeMergeProjectionPanel({ gateway, enabled, disabled = false, refreshKey }: KnowledgeMergeProjectionPanelProps) {
  const [pathValue, setPathValue] = useState<string | null>(null);
  const [strategy, setStrategy] = useState<KnowledgeRestoreStrategy>("requireNoIdentityConflicts");
  const [plan, setPlan] = useState<KnowledgeMergeProjectionPlan | null>(null);
  const [receipt, setReceipt] = useState<KnowledgeMergeProjectionReceipt | null>(null);
  const [consent, setConsent] = useState(false);
  const [busy, setBusy] = useState<"selecting" | "planning" | "preflighting" | null>(null);
  const [error, setError] = useState("");
  const renderContext = { gateway, enabled, disabled, refreshKey, path: pathValue, strategy };
  const contextRef = useRef({ ...renderContext, consent });
  contextRef.current = { ...renderContext, consent };
  type Context = typeof renderContext;
  const planRef = useRef<KnowledgeMergeProjectionPlan | null>(null);
  const binding = useRef<{ plan: KnowledgeMergeProjectionPlan; snapshot: string; context: Context } | null>(null);
  const receiptContext = useRef<Context | null>(null);
  const generation = useRef(0);
  const busyRef = useRef(false);
  const usable = enabled && !disabled;
  const same = (a: Context) => {
    const c = contextRef.current;
    return a.gateway === c.gateway && a.enabled === c.enabled && a.disabled === c.disabled
      && a.refreshKey === c.refreshKey && a.path === c.path && a.strategy === c.strategy;
  };
  const discard = (p: KnowledgeMergeProjectionPlan | null, g: KnowledgeMergeProjectionGateway | undefined) => {
    if (p && g) void g.discardKnowledgeMergeProjection(p.planId).catch(() => undefined);
  };
  const clear = () => {
    discard(planRef.current, binding.current?.context.gateway);
    planRef.current = null; binding.current = null; receiptContext.current = null;
    contextRef.current.consent = false;
    generation.current += 1;
    setPlan(null); setReceipt(null); setConsent(false); setError("");
  };
  const bound = (p: KnowledgeMergeProjectionPlan | null) => {
    const b = binding.current;
    return !!p && planRef.current === p && b?.plan === p && same(b.context)
      && snapshot(p) === b.snapshot && validKnowledgeMergeProjectionPlan(p, contextRef.current.path ?? "", contextRef.current.strategy);
  };
  const current = usable && same(renderContext) && bound(plan) ? plan : null;
  const ready = current?.projection.state === "validated" && current.projectedManifestValidated
    && current.source.qualification.state === "evidenceReady";

  useEffect(() => {
    clear(); busyRef.current = false;
    contextRef.current.path = null; contextRef.current.strategy = "requireNoIdentityConflicts";
    setPathValue(null); setStrategy("requireNoIdentityConflicts"); setBusy(null);
    return () => {
      discard(planRef.current, binding.current?.context.gateway);
      planRef.current = null; binding.current = null; receiptContext.current = null;
      generation.current += 1; busyRef.current = false;
    };
  }, [gateway, enabled, disabled, refreshKey]);

  useEffect(() => {
    if (!plan) return;
    const timer = window.setTimeout(() => {
      if (planRef.current === plan) {
        clear(); setError("投影计划已过期，请重新生成。");
      }
    }, Math.max(0, plan.expiresAtEpochMs - Date.now()));
    return () => window.clearTimeout(timer);
  }, [plan?.planId, plan?.expiresAtEpochMs]);

  async function select() {
    const ctx = { ...contextRef.current };
    if (!same(renderContext) || !ctx.enabled || ctx.disabled || busyRef.current) return;
    clear();
    const req = ++generation.current; busyRef.current = true; setBusy("selecting");
    try {
      const next = await ctx.gateway.selectKnowledgeCandidateDirectory();
      if (req !== generation.current || !same(ctx)) return;
      if (next !== null && !candidatePath(next)) throw new Error();
      contextRef.current.path = next; setPathValue(next);
    } catch {
      if (req === generation.current && same(ctx)) setError("无法选择候选目录。");
    } finally {
      if (req === generation.current) { busyRef.current = false; setBusy(null); }
    }
  }

  async function createPlan() {
    const ctx = { ...contextRef.current };
    const selected = pathValue;
    if (!same(renderContext) || ctx.path !== selected || !candidatePath(selected)
      || !ctx.enabled || ctx.disabled || busyRef.current) return;
    clear();
    const req = ++generation.current; busyRef.current = true; setBusy("planning");
    try {
      const next: unknown = await ctx.gateway.planKnowledgeMergeProjection(selected!, ctx.strategy);
      if (req !== generation.current || !same(ctx)) {
        if (recognizable(next)) discard(next as KnowledgeMergeProjectionPlan, ctx.gateway);
        return;
      }
      if (!validKnowledgeMergeProjectionPlan(next, selected!, ctx.strategy)) {
        if (recognizable(next)) discard(next as KnowledgeMergeProjectionPlan, ctx.gateway);
        throw new Error();
      }
      const accepted = copy(next);
      if (!validKnowledgeMergeProjectionPlan(accepted, selected!, ctx.strategy)) throw new Error();
      planRef.current = accepted;
      binding.current = { plan: accepted, snapshot: snapshot(accepted), context: ctx };
      setPlan(accepted);
    } catch {
      if (req === generation.current && same(ctx)) setError("投影计划无效或已超过固定限制。");
    } finally {
      if (req === generation.current) { busyRef.current = false; setBusy(null); }
    }
  }

  async function preflight() {
    const old = current;
    const ctx = { ...contextRef.current };
    if (!old || !ready || !same(renderContext) || !ctx.enabled || ctx.disabled || !consent
      || !ctx.consent || !bound(old) || busyRef.current) return;
    const oldSnapshot = binding.current!.snapshot;
    planRef.current = null; binding.current = null; receiptContext.current = null;
    contextRef.current.consent = false;
    setPlan(null); setReceipt(null); setConsent(false); setError("");
    const req = ++generation.current; busyRef.current = true; setBusy("preflighting");
    try {
      const next: unknown = await ctx.gateway.preflightKnowledgeMergeProjection(old.planId, true);
      if (req !== generation.current || !same(ctx)) return;
      if (snapshot(old) !== oldSnapshot || Date.now() >= old.expiresAtEpochMs || !receiptValid(next, old)) throw new Error();
      const accepted = copy(next);
      if (!receiptValid(accepted, old)) throw new Error();
      receiptContext.current = ctx; setReceipt(accepted);
    } catch {
      if (req === generation.current && same(ctx)) setError("内存复验失败；该计划已消费，请重新生成。");
    } finally {
      discard(old, ctx.gateway);
      if (req === generation.current) { busyRef.current = false; setBusy(null); }
    }
  }

  function changeStrategy(value: KnowledgeRestoreStrategy) {
    const ctx = contextRef.current;
    if (!same(renderContext) || !ctx.enabled || ctx.disabled || !strategies.includes(value)
      || value === ctx.strategy || busyRef.current) return;
    clear(); contextRef.current.strategy = value; setStrategy(value);
  }
  function changeConsent(value: boolean) {
    const ctx = contextRef.current;
    if (!same(renderContext) || !ctx.enabled || ctx.disabled || !ready || !bound(current) || busyRef.current) return;
    contextRef.current.consent = value; setConsent(value);
  }
  function cancel() {
    if (!same(renderContext) || !usable || busyRef.current || !bound(current)) return;
    clear();
  }

  const p = current?.projection;
  const shownReceipt = usable && receiptContext.current && same(receiptContext.current) ? receipt : null;
  return <section className="operation-plan" aria-label="知识库合并投影" aria-busy={busy !== null}>
    <h4>知识库合并投影（只读）</h4>
    <p className="publish-muted">生成合并清单的内存投影，保留当前资料及其权限；新增资料的 AI 与语义索引授权关闭。</p>
    <p className="publish-warning">仅核验已保存的资料引用；来源真实性、外部附件和未引用文件仍未验证。当前资料库不变。</p>
    <button type="button" onClick={() => void select()} disabled={!usable || busy !== null}>选择候选目录</button>
    {pathValue && <p>候选路径：{pathValue}</p>}
    <label>恢复策略：<select value={strategy} onChange={e => changeStrategy(e.target.value as KnowledgeRestoreStrategy)} disabled={!usable || busy !== null}>
      {strategies.map(value => <option key={value} value={value}>{strategyLabel(value)}</option>)}
    </select></label>
    {pathValue && <button type="button" onClick={() => void createPlan()} disabled={!usable || busy !== null}>生成内存投影</button>}
    {busy && <p role="status">正在{busy === "selecting" ? "选择目录" : busy === "planning" ? "生成投影" : "复验投影"}…</p>}
    {error && <p role="alert" className="publish-warning">{error}</p>}
    {current && p && <div className="operation-plan">
      <p><strong>投影摘要（一次性，5 分钟内有效）</strong></p>
      <p>策略：{strategyLabel(strategy)}；结果：{reasonLabel[p.reason]}</p>
      <p>清单 SHA-256：{p.manifestSha256 ?? "未知"}</p>
      <p>资料项：{p.itemCount ?? "未知"}；历史修订：{p.revisionCount ?? "未知"}；分类：{p.folderCount ?? "未知"}；资源文件：{p.fileCount ?? "未知"}；资源字节：{p.resourceByteSize ?? "未知"}</p>
      <p>导入资料项：{p.importedItems ?? "未知"}；导入分类：{p.importedFolders ?? "未知"}；关闭原有权限的新增资料项：{p.resetPermissionItems ?? "未知"}</p>
      {ready && <>
        <label><input type="checkbox" checked={consent} onChange={e => changeConsent(e.target.checked)} disabled={busy !== null} />我确认新增资料的 AI 与语义索引授权关闭，当前资料权限保留；本次仅做内存复验。</label>
        <button type="button" onClick={() => void preflight()} disabled={!consent || busy !== null}>确认并做内存复验</button>
      </>}
      <button type="button" onClick={cancel} disabled={busy !== null}>取消投影</button>
    </div>}
    {shownReceipt && <div className="operation-plan">
      <p role="status">内存复验完成：投影摘要与复验回执一致；当前资料库不变。</p>
      <p>资料项：{shownReceipt.itemCount}；历史修订：{shownReceipt.revisionCount}；分类：{shownReceipt.folderCount}；导入资料项：{shownReceipt.importedItems}；导入分类：{shownReceipt.importedFolders}</p>
    </div>}
  </section>;
}
