import { useEffect, useRef, useState } from "react";
import { KNOWLEDGE_CANDIDATE_CHECK_LIMITS, type KnowledgeCandidateCheckReport, type KnowledgeCandidateConflicts } from "../contracts/knowledgeCandidateCheck";
import type { KnowledgeRestoreQualificationGateway, KnowledgeRestoreQualificationPlan, KnowledgeRestoreQualificationRecheck, KnowledgeRestoreStrategy } from "../contracts/knowledgeRestoreQualification";
export interface KnowledgeRestoreQualificationPanelProps {
    gateway: KnowledgeRestoreQualificationGateway;
    enabled: boolean;
    disabled?: boolean;
    refreshKey?: number;
}
const TTL = 300000;
const MAX_TIME = 8.64e15;
const candidateStates = new Set(["checked", "missing", "unsafe", "unreadable", "invalid", "changed"]);
const resourceStates = new Set(["notChecked", "checked", "missing", "unsafe", "unreadable", "invalid", "changed", "overLimit", "incomplete"]);
const strategies: KnowledgeRestoreStrategy[] = ["requireNoIdentityConflicts", "keepCurrentIdentities"];
const candidateKeys = ["reportId", "candidatePath", "schemaVersion", "scope", "stagePlanId", "sourcePackageSha256", "manifestSha256", "candidateInventorySha256", "candidateFileCount", "candidateByteSize", "itemCount", "revisionCount", "folderCount", "currentLibrary", "conflicts", "limits", "candidateStructureVerified", "candidateContentsVerified", "privatePermissionsVerified", "sourcePackageHashVerified", "candidateAuthenticityVerified", "currentLibraryResourcesVerified", "comparisonScope", "consistentSnapshot", "filesystemWrites", "currentLibraryChanged", "restoreReady", "checkedAtEpochMs", "expiresAtEpochMs"] as const;
const currentKeys = ["state", "manifestSha256", "itemCount", "revisionCount", "folderCount"] as const;
const conflictKeys = ["candidateOnlyItems", "currentOnlyItems", "identicalItems", "changedItems", "candidateOnlyFolders", "currentOnlyFolders", "identicalFolders", "changedFolders"] as const;
const limitKeys = ["manifestBytes", "resourceFiles", "resourceBytes", "candidateFiles", "candidateBytes", "markerBytes", "jsonNodes", "durationMs"] as const;
const resourceKeys = ["state", "fileCount", "byteSize", "inventorySha256", "unreferencedFilesVerified", "externalReferencesVerified"] as const;
const qualificationKeys = ["state", "reason", "addItems", "retainItems", "skipCandidateItems", "addFolders", "retainFolders", "skipCandidateFolders"] as const;
const planKeys = ["schemaVersion", "scope", "planId", "targetScope", "candidate", "currentResources", "strategy", "qualification", "currentOnlyPreserved", "candidatePermissionsApplied", "projectedManifestValidated", "consistentSnapshot", "filesystemWrites", "restoreReady", "checkedAtEpochMs", "expiresAtEpochMs"] as const;
const exact = (value: unknown, keys: readonly string[]) => !!value && typeof value === "object" && Object.keys(value as object).length === keys.length && keys.every((key) => Object.prototype.hasOwnProperty.call(value as object, key));
const integer = (value: unknown): value is number => typeof value === "number" && Number.isSafeInteger(value) && value >= 0;
const time = (value: unknown) => integer(value) && value > 0 && value <= MAX_TIME;
const sha = (value: unknown) => typeof value === "string" && /^[0-9a-f]{64}$/.test(value);
const uuid = (value: unknown): value is string => typeof value === "string" && /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(value);
const path = (value: unknown): value is string => typeof value === "string" && value.startsWith("/") && new TextEncoder().encode(value).byteLength <= 4096 && !value.includes("\0") && value !== "/" && !value.endsWith("/") && !value.includes("//") && value.slice(1).split("/").every((part) => part !== "." && part !== "..");
const candidatePath = (value: unknown) => path(value) && /^repopress-knowledge-stage-[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(value.slice(value.lastIndexOf("/") + 1));
const validCounts = (value: unknown) => value === null || integer(value);
const validLimits = (value: unknown) => !!value && exact(value, limitKeys) && limitKeys.every((key) => (value as Record<string, unknown>)[key] === KNOWLEDGE_CANDIDATE_CHECK_LIMITS[key]);
const validCurrent = (value: unknown): value is KnowledgeCandidateCheckReport["currentLibrary"] => {
    if (!exact(value, currentKeys))
        return false;
    const current = value as KnowledgeCandidateCheckReport["currentLibrary"];
    if (!candidateStates.has(current.state))
        return false;
    if (current.state !== "checked")
        return current.manifestSha256 === null && current.itemCount === null && current.revisionCount === null && current.folderCount === null;
    return sha(current.manifestSha256) && integer(current.itemCount) && integer(current.revisionCount) && integer(current.folderCount) && current.itemCount !== null && current.revisionCount !== null && current.folderCount !== null && current.itemCount <= 2000 && current.revisionCount >= current.itemCount && current.revisionCount <= current.itemCount * 32 && current.folderCount <= 128;
};
const validConflicts = (value: unknown): value is KnowledgeCandidateConflicts => !!value && exact(value, conflictKeys) && conflictKeys.every((key) => integer((value as Record<string, unknown>)[key]));
function validCandidate(value: unknown, now = Date.now()): value is KnowledgeCandidateCheckReport {
    if (!exact(value, candidateKeys))
        return false;
    const x = value as KnowledgeCandidateCheckReport;
    if (!uuid(x.reportId) || !candidatePath(x.candidatePath) || x.schemaVersion !== 1 || x.scope !== "selectedKnowledgeCandidate" || !uuid(x.stagePlanId) || x.stagePlanId !== x.candidatePath.slice(x.candidatePath.lastIndexOf("/") + 1).slice("repopress-knowledge-stage-".length) || !sha(x.sourcePackageSha256) || !sha(x.manifestSha256) || !sha(x.candidateInventorySha256) || !integer(x.candidateFileCount) || x.candidateFileCount < 2 || x.candidateFileCount > KNOWLEDGE_CANDIDATE_CHECK_LIMITS.candidateFiles || !integer(x.candidateByteSize) || x.candidateByteSize <= 0 || x.candidateByteSize > KNOWLEDGE_CANDIDATE_CHECK_LIMITS.candidateBytes || !integer(x.itemCount) || !integer(x.revisionCount) || !integer(x.folderCount) || x.itemCount > 2000 || x.revisionCount < x.itemCount || x.revisionCount > x.itemCount * 32 || (x.itemCount === 0 ? x.revisionCount !== 0 || x.candidateFileCount !== 2 : x.candidateFileCount < 3 || x.candidateFileCount > x.revisionCount * 2 + 2) || x.folderCount > 128 || !validCurrent(x.currentLibrary) || !validLimits(x.limits) || x.candidateStructureVerified !== true || x.candidateContentsVerified !== true || x.privatePermissionsVerified !== true || x.sourcePackageHashVerified !== false || x.candidateAuthenticityVerified !== false || x.currentLibraryResourcesVerified !== false || x.comparisonScope !== "manifestIdentityAndMetadataOnly" || x.consistentSnapshot !== false || x.filesystemWrites !== false || x.currentLibraryChanged !== false || x.restoreReady !== false || !time(x.checkedAtEpochMs) || !time(x.expiresAtEpochMs) || x.checkedAtEpochMs > now || x.expiresAtEpochMs <= now || x.expiresAtEpochMs - x.checkedAtEpochMs !== TTL)
        return false;
    if (x.currentLibrary.state !== "checked")
        return x.conflicts === null;
    return validConflicts(x.conflicts) && x.conflicts.candidateOnlyItems + x.conflicts.identicalItems + x.conflicts.changedItems === x.itemCount && x.conflicts.currentOnlyItems + x.conflicts.identicalItems + x.conflicts.changedItems === x.currentLibrary.itemCount && x.conflicts.candidateOnlyFolders + x.conflicts.identicalFolders + x.conflicts.changedFolders === x.folderCount && x.conflicts.currentOnlyFolders + x.conflicts.identicalFolders + x.conflicts.changedFolders === x.currentLibrary.folderCount;
}
function validResources(value: unknown): boolean {
    if (!exact(value, resourceKeys))
        return false;
    const x = value as KnowledgeRestoreQualificationPlan["currentResources"];
    if (!resourceStates.has(x.state) || x.unreferencedFilesVerified !== false || x.externalReferencesVerified !== false)
        return false;
    if (x.state !== "checked")
        return x.fileCount === null && x.byteSize === null && x.inventorySha256 === null;
    return integer(x.fileCount) && x.fileCount !== null && x.fileCount <= KNOWLEDGE_CANDIDATE_CHECK_LIMITS.resourceFiles && integer(x.byteSize) && x.byteSize !== null && x.byteSize <= KNOWLEDGE_CANDIDATE_CHECK_LIMITS.resourceBytes && sha(x.inventorySha256);
}
export function validKnowledgeRestoreQualificationPlan(value: unknown, selectedPath: string, strategy: KnowledgeRestoreStrategy, now = Date.now()): value is KnowledgeRestoreQualificationPlan {
    if (!exact(value, planKeys))
        return false;
    const x = value as KnowledgeRestoreQualificationPlan;
    // The remaining checks intentionally stay local to the UI boundary.
    if (x.schemaVersion !== 1 || x.scope !== "knowledgeRestoreQualification" || !uuid(x.planId) || x.targetScope !== "currentAppKnowledgeLibrary" || !validCandidate(x.candidate, now) || x.candidate.candidatePath !== selectedPath || x.checkedAtEpochMs !== x.candidate.checkedAtEpochMs || x.expiresAtEpochMs !== x.candidate.expiresAtEpochMs || !validResources(x.currentResources) || !strategies.includes(x.strategy) || x.strategy !== strategy || !exact(x.qualification, qualificationKeys) || !["evidenceReady", "blocked"].includes(x.qualification.state) || !["none", "currentManifestUnavailable", "currentResourcesUnavailable", "identityConflicts"].includes(x.qualification.reason) || x.currentOnlyPreserved !== true || x.candidatePermissionsApplied !== false || x.projectedManifestValidated !== false || x.consistentSnapshot !== false || x.filesystemWrites !== false || x.restoreReady !== false || !time(x.checkedAtEpochMs) || !time(x.expiresAtEpochMs) || x.checkedAtEpochMs > now || x.expiresAtEpochMs <= now || x.expiresAtEpochMs - x.checkedAtEpochMs !== TTL)
        return false;
    const q = x.qualification;
    if (![q.addItems, q.retainItems, q.skipCandidateItems, q.addFolders, q.retainFolders, q.skipCandidateFolders].every(validCounts))
        return false;
    const unknownCurrent = x.candidate.currentLibrary.state !== "checked";
    if (unknownCurrent)
        return x.currentResources.state === "notChecked" || x.currentResources.state === "changed" ? q.state === "blocked" && q.reason === "currentManifestUnavailable" && [q.addItems, q.retainItems, q.skipCandidateItems, q.addFolders, q.retainFolders, q.skipCandidateFolders].every((v) => v === null) : false;
    if (x.currentResources.state !== "checked")
        return q.state === "blocked" && q.reason === "currentResourcesUnavailable" && [q.addItems, q.retainItems, q.skipCandidateItems, q.addFolders, q.retainFolders, q.skipCandidateFolders].every((v) => v === null);
    const resources = x.currentResources;
    const revisions = x.candidate.currentLibrary.revisionCount!;
    if (resources.fileCount! > revisions * 2 || (revisions === 0 ? resources.fileCount !== 0 || resources.byteSize !== 0 : resources.fileCount! < 1))
        return false;
    const c = x.candidate.conflicts;
    if (!c)
        return false;
    const conflict = c.changedItems > 0 || c.changedFolders > 0;
    const expected = [c.candidateOnlyItems, x.candidate.currentLibrary.itemCount, c.changedItems + c.identicalItems, c.candidateOnlyFolders, x.candidate.currentLibrary.folderCount, c.changedFolders + c.identicalFolders];
    if (conflict && x.strategy === "requireNoIdentityConflicts")
        return q.state === "blocked" && q.reason === "identityConflicts" && [q.addItems, q.retainItems, q.skipCandidateItems, q.addFolders, q.retainFolders, q.skipCandidateFolders].every((v) => v === null);
    return q.reason === "none" && q.state === "evidenceReady" && [q.addItems, q.retainItems, q.skipCandidateItems, q.addFolders, q.retainFolders, q.skipCandidateFolders].every((v, i) => v === expected[i]);
}
export const knowledgeRestoreQualificationSnapshot = (plan: KnowledgeRestoreQualificationPlan) => JSON.stringify([
    plan.candidate.candidatePath, plan.candidate.sourcePackageSha256, plan.candidate.manifestSha256,
    plan.candidate.candidateInventorySha256, plan.candidate.candidateFileCount, plan.candidate.candidateByteSize,
    plan.candidate.itemCount, plan.candidate.revisionCount, plan.candidate.folderCount,
    currentKeys.map(key => plan.candidate.currentLibrary[key]),
    plan.candidate.conflicts ? conflictKeys.map(key => plan.candidate.conflicts![key]) : null,
    resourceKeys.map(key => plan.currentResources[key]), plan.strategy,
    qualificationKeys.map(key => plan.qualification[key]),
]);
const comparable = (plan: KnowledgeRestoreQualificationPlan) => plan.candidate.currentLibrary.state === "checked" && plan.currentResources.state === "checked";
const recognizablePlanId = (value: unknown) => !!value && typeof value === "object" && uuid((value as Partial<KnowledgeRestoreQualificationPlan>).planId);
const strategyLabel = (strategy: KnowledgeRestoreStrategy) => strategy === "requireNoIdentityConflicts" ? "要求无身份冲突" : "保留当前身份";
export function KnowledgeRestoreQualificationPanel({ gateway, enabled, disabled = false, refreshKey }: KnowledgeRestoreQualificationPanelProps) {
    const [pathValue, setPathValue] = useState<string | null>(null);
    const [strategy, setStrategy] = useState<KnowledgeRestoreStrategy>("requireNoIdentityConflicts");
    const [plan, setPlan] = useState<KnowledgeRestoreQualificationPlan | null>(null);
    const [comparison, setComparison] = useState<KnowledgeRestoreQualificationRecheck["comparison"] | null>(null);
    const [busy, setBusy] = useState<"selecting" | "planning" | "rechecking" | null>(null);
    const [error, setError] = useState("");
    const contextRef = useRef({ gateway, enabled, disabled, refreshKey, path: pathValue, strategy });
    contextRef.current = { gateway, enabled, disabled, refreshKey, path: pathValue, strategy };
    const planRef = useRef<KnowledgeRestoreQualificationPlan | null>(null);
    const bindingRef = useRef<{
        plan: KnowledgeRestoreQualificationPlan;
        context: typeof contextRef.current;
    } | null>(null);
    const generation = useRef(0);
    const busyRef = useRef(false);
    const usable = enabled && !disabled;
    const same = (a: typeof contextRef.current, b = contextRef.current) => a.gateway === b.gateway && a.enabled === b.enabled && a.disabled === b.disabled && a.refreshKey === b.refreshKey && a.path === b.path && a.strategy === b.strategy;
    const discard = (value: KnowledgeRestoreQualificationPlan | null, g: KnowledgeRestoreQualificationGateway | undefined) => { if (value && g)
        void g.discardKnowledgeRestoreQualification(value.planId).catch(() => undefined); };
    const clear = (discardCurrent = true) => { const current = planRef.current; if (discardCurrent)
        discard(current, bindingRef.current?.context.gateway); planRef.current = null; bindingRef.current = null; generation.current += 1; setPlan(null); setComparison(null); setError(""); };
    const current = usable && planRef.current === plan && bindingRef.current?.plan === plan && same(bindingRef.current.context) && pathValue === plan?.candidate.candidatePath && plan && plan.expiresAtEpochMs > Date.now() ? plan : null;
    useEffect(() => { clear(); busyRef.current = false; setPathValue(null); setStrategy("requireNoIdentityConflicts"); setBusy(null); return () => { discard(planRef.current, bindingRef.current?.context.gateway); planRef.current = null; bindingRef.current = null; generation.current += 1; busyRef.current = false; }; }, [gateway, enabled, disabled, refreshKey]);
    useEffect(() => { if (!plan)
        return; const timer = window.setTimeout(() => { if (planRef.current !== plan)
        return; clear(); setError("资格计划已过期，请重新选择目录并生成计划。"); }, Math.max(0, plan.expiresAtEpochMs - Date.now())); return () => window.clearTimeout(timer); }, [plan?.planId, plan?.expiresAtEpochMs]);
    async function select() { const ctx = { ...contextRef.current }; if (!ctx.enabled || ctx.disabled || ctx.gateway !== gateway || ctx.strategy !== strategy || busyRef.current)
        return; clear(); const request = ++generation.current; busyRef.current = true; setBusy("selecting"); try {
        const next = await ctx.gateway.selectKnowledgeCandidateDirectory();
        if (request !== generation.current || !same(ctx) || !contextRef.current.enabled || contextRef.current.disabled)
            return;
        if (next !== null && !candidatePath(next))
            throw new Error("invalid");
        setPathValue(next);
        contextRef.current.path = next;
        ctx.path = next;
    }
    catch {
        if (request === generation.current && same(ctx))
            setError("无法选择候选目录，请重新选择。");
    }
    finally {
        if (request === generation.current && same(ctx)) {
            busyRef.current = false;
            setBusy(null);
        }
    } }
    async function createPlan() { const ctx = { ...contextRef.current }; const selected = pathValue; if (!ctx.enabled || ctx.disabled || ctx.gateway !== gateway || ctx.strategy !== strategy || ctx.path !== selected || busyRef.current || !selected || !candidatePath(selected))
        return; clear(); const request = ++generation.current; busyRef.current = true; setBusy("planning"); try {
        const next: unknown = await ctx.gateway.planKnowledgeRestoreQualification(selected, ctx.strategy);
        if (request !== generation.current || !same(ctx) || contextRef.current.path !== selected) {
            if (recognizablePlanId(next))
                discard(next as KnowledgeRestoreQualificationPlan, ctx.gateway);
            return;
        }
        if (!validKnowledgeRestoreQualificationPlan(next, selected, ctx.strategy)) {
            if (recognizablePlanId(next))
                discard(next as KnowledgeRestoreQualificationPlan, ctx.gateway);
            throw new Error("invalid");
        }
        const accepted = next as KnowledgeRestoreQualificationPlan;
        planRef.current = accepted;
        bindingRef.current = { plan: accepted, context: ctx };
        setPlan(accepted);
    }
    catch {
        if (request === generation.current && same(ctx))
            setError("资格计划无效或已超过固定限制。");
    }
    finally {
        if (request === generation.current && same(ctx)) {
            busyRef.current = false;
            setBusy(null);
        }
    } }
    async function recheck() { const old = current; const binding = bindingRef.current; const ctx = { ...contextRef.current }; if (!old || !binding || binding.plan !== old || !same(binding.context) || !same(ctx) || busyRef.current || old.expiresAtEpochMs <= Date.now())
        return; planRef.current = null; bindingRef.current = null; setPlan(null); setComparison(null); setError(""); const request = ++generation.current; busyRef.current = true; setBusy("rechecking"); try {
        const next: unknown = await ctx.gateway.recheckKnowledgeRestoreQualification(old.planId);
        if (request !== generation.current || !same(ctx)) {
            if (recognizablePlanId((next as Partial<KnowledgeRestoreQualificationRecheck>)?.plan))
                discard((next as KnowledgeRestoreQualificationRecheck).plan, ctx.gateway);
            return;
        }
        const wrapper = next as Partial<KnowledgeRestoreQualificationRecheck>;
        const value = wrapper?.plan as KnowledgeRestoreQualificationPlan | undefined;
        const comparison = wrapper?.comparison;
        const validComparison = comparison === "unchanged" || comparison === "changed" || comparison === "inconclusive";
        const validValue = validKnowledgeRestoreQualificationPlan(value, old.candidate.candidatePath, old.strategy);
        const sameSnapshot = validValue ? knowledgeRestoreQualificationSnapshot(value) === knowledgeRestoreQualificationSnapshot(old) : false;
        const bothComparable = validValue && comparable(old) && comparable(value);
        const snapshotMatchesComparison = comparison === "unchanged" ? bothComparable && sameSnapshot : comparison === "changed" ? bothComparable : !bothComparable;
        if (!wrapper || !exact(wrapper, ["plan", "comparison"]) || !validComparison || !validValue || value.planId === old.planId || value.candidate.reportId === old.candidate.reportId || value.candidate.stagePlanId !== old.candidate.stagePlanId || !snapshotMatchesComparison) {
            if (recognizablePlanId(wrapper?.plan))
                discard(value as KnowledgeRestoreQualificationPlan, ctx.gateway);
            throw new Error("invalid");
        }
        planRef.current = value;
        bindingRef.current = { plan: value, context: ctx };
        setPlan(value);
        setComparison(comparison);
    }
    catch {
        discard(old, ctx.gateway);
        if (request === generation.current && same(ctx))
            setError("重新核对失败；旧资格计划已消耗，请重新生成计划。");
    }
    finally {
        if (request === generation.current && same(ctx)) {
            busyRef.current = false;
            setBusy(null);
        }
    } }
    const changeStrategy = (value: KnowledgeRestoreStrategy) => { const ctx = contextRef.current; if (!ctx.enabled || ctx.disabled || ctx.gateway !== gateway || ctx.strategy !== strategy || busyRef.current || !strategies.includes(value) || value === strategy)
        return; clear(); setStrategy(value); contextRef.current.strategy = value; };
    const q = current?.qualification;
    const c = current?.candidate.conflicts;
    return <section className="operation-plan" aria-label="知识库恢复资格" aria-busy={busy !== null}><h4>知识库恢复资格（只读计划）</h4><p className="publish-muted">仅生成恢复资格证据和策略摘要，不写入当前资料库，不执行恢复。</p><p className="publish-warning">不证明来源真实性、当前未引用文件闭包、外部引用闭包或合并后的清单；不会应用候选 AI 偏好。</p><button type="button" onClick={() => void select()} disabled={!usable || busy !== null}>选择候选目录</button>{pathValue && <p>候选路径：{pathValue}</p>}<label>恢复策略：<select value={strategy} onChange={(event) => changeStrategy(event.target.value as KnowledgeRestoreStrategy)} disabled={!usable || busy !== null}><option value="requireNoIdentityConflicts">要求无身份冲突</option><option value="keepCurrentIdentities">保留当前身份</option></select></label>{pathValue && <button type="button" onClick={() => void createPlan()} disabled={!usable || busy !== null}>生成只读资格计划</button>}{busy && <p role="status">{busy === "selecting" ? "正在选择候选目录…" : busy === "planning" ? "正在生成资格计划…" : "正在重新核对资格计划…"}</p>}{error && <p role="alert" className="publish-warning">{error}</p>}{current && <div className="operation-plan"><p><strong>资格证据（一次性，5 分钟内有效）</strong></p><p>策略：{strategyLabel(current.strategy)}；候选路径：{current.candidate.candidatePath}</p><p>候选清单 SHA-256：{current.candidate.manifestSha256}；候选文件清单 SHA-256：{current.candidate.candidateInventorySha256}；候选文件：{current.candidate.candidateFileCount}；候选字节：{current.candidate.candidateByteSize}</p><p>当前资源状态：{current.currentResources.state}；文件：{current.currentResources.fileCount ?? "未知"}；字节：{current.currentResources.byteSize ?? "未知"}；资源清单 SHA-256：{current.currentResources.inventorySha256 ?? "未知"}</p><p>当前清单状态：{current.candidate.currentLibrary.state}；候选资料项：{current.candidate.itemCount}；候选历史修订：{current.candidate.revisionCount}；候选文件夹：{current.candidate.folderCount}</p>{c && <p>冲突摘要：候选新增资料项 {c.candidateOnlyItems}；当前独有 {c.currentOnlyItems}；相同 {c.identicalItems}；变化 {c.changedItems}；候选新增文件夹 {c.candidateOnlyFolders}；当前独有 {c.currentOnlyFolders}；相同 {c.identicalFolders}；变化 {c.changedFolders}</p>}{q && <p>资格：{q.state}；原因：{q.reason}；新增资料项 {q.addItems ?? "未知"}；保留当前资料项 {q.retainItems ?? "未知"}；跳过候选资料项 {q.skipCandidateItems ?? "未知"}；新增文件夹 {q.addFolders ?? "未知"}；保留当前文件夹 {q.retainFolders ?? "未知"}；跳过候选文件夹 {q.skipCandidateFolders ?? "未知"}</p>}<p>证据仅供后续人工审阅；restoreReady=false，projectedManifestValidated=false，filesystemWrites=false。</p><button type="button" onClick={() => void recheck()} disabled={!usable || busy !== null}>一次性重新核对</button><button type="button" onClick={() => clear()} disabled={busy !== null}>取消计划</button>{comparison && <p role="status">重新核对结果：{comparison === "unchanged" ? "未变化" : comparison === "changed" ? "已变化" : "无法确定"}</p>}</div>}</section>;
}
