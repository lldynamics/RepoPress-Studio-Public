import { useEffect, useRef, useState } from "react";
import { useI18n } from "../i18n/i18n";
import { knowledgeCandidateMessages } from "../i18n/knowledgeCandidateMessages";
import { KNOWLEDGE_CANDIDATE_CHECK_LIMITS, type KnowledgeCandidateCheckGateway, type KnowledgeCandidateCheckReport, type KnowledgeCandidateConflicts, type KnowledgeCandidateRecheck } from "../contracts/knowledgeCandidateCheck";
export interface KnowledgeCandidateCheckPanelProps {
    gateway: KnowledgeCandidateCheckGateway;
    enabled: boolean;
    disabled?: boolean;
    refreshKey?: number;
}
const TTL = 300000;
const MAX_TIME = 8.64e15;
const currentStateLabels: Record<string, string> = { checked: "已核验", missing: "缺失", unsafe: "不安全", unreadable: "不可读取", invalid: "无效", changed: "已变化" };
const uuidV4 = (v: unknown): v is string => typeof v === "string" && /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(v);
const sha = (v: unknown): v is string => typeof v === "string" && /^[0-9a-f]{64}$/.test(v);
const integer = (v: unknown): v is number => typeof v === "number" && Number.isSafeInteger(v) && v >= 0;
const time = (v: unknown): v is number => integer(v) && v > 0 && v <= MAX_TIME;
const lexicalPath = (v: unknown): v is string => typeof v === "string" && v.startsWith("/") && new TextEncoder().encode(v).byteLength <= 4096 && !v.includes("\0") && (v === "/" || (!v.endsWith("/") && !v.includes("//") && v.slice(1).split("/").every((part) => part !== "." && part !== ".." && part !== "")));
const candidatePath = (v: unknown): v is string => lexicalPath(v) && v !== "/" && /^repopress-knowledge-stage-[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(v.slice(v.lastIndexOf("/") + 1));
const stageIdFromPath = (v: string) => v.slice(v.lastIndexOf("/") + 1).slice("repopress-knowledge-stage-".length);
const exact = (v: object, keys: readonly string[]) => Object.keys(v).length === keys.length && keys.every((key) => Object.prototype.hasOwnProperty.call(v, key));
const limitKeys = ["manifestBytes", "resourceFiles", "resourceBytes", "candidateFiles", "candidateBytes", "markerBytes", "jsonNodes", "durationMs"] as const;
const exactLimits = (v: unknown): v is typeof KNOWLEDGE_CANDIDATE_CHECK_LIMITS => !!v && typeof v === "object" && exact(v, limitKeys) && limitKeys.every((key) => (v as Record<string, unknown>)[key] === KNOWLEDGE_CANDIDATE_CHECK_LIMITS[key]);
const conflictKeys = ["candidateOnlyItems", "currentOnlyItems", "identicalItems", "changedItems", "candidateOnlyFolders", "currentOnlyFolders", "identicalFolders", "changedFolders"] as const;
const validConflicts = (v: unknown): v is KnowledgeCandidateConflicts => !!v && typeof v === "object" && exact(v, conflictKeys) && conflictKeys.every((key) => integer((v as Record<string, unknown>)[key]));
const currentKeys = ["state", "manifestSha256", "itemCount", "revisionCount", "folderCount"] as const;
const states = new Set(["checked", "missing", "unsafe", "unreadable", "invalid", "changed"]);
function validCurrent(v: unknown): v is KnowledgeCandidateCheckReport["currentLibrary"] {
    if (!v || typeof v !== "object" || !exact(v, currentKeys))
        return false;
    const x = v as KnowledgeCandidateCheckReport["currentLibrary"];
    if (!states.has(x.state))
        return false;
    const known = x.state === "checked";
    return (known ? sha(x.manifestSha256) && integer(x.itemCount) && integer(x.revisionCount) && integer(x.folderCount) : x.manifestSha256 === null && x.itemCount === null && x.revisionCount === null && x.folderCount === null);
}
const reportKeys = ["reportId", "candidatePath", "schemaVersion", "scope", "stagePlanId", "sourcePackageSha256", "manifestSha256", "candidateInventorySha256", "candidateFileCount", "candidateByteSize", "itemCount", "revisionCount", "folderCount", "currentLibrary", "conflicts", "limits", "candidateStructureVerified", "candidateContentsVerified", "privatePermissionsVerified", "sourcePackageHashVerified", "candidateAuthenticityVerified", "currentLibraryResourcesVerified", "comparisonScope", "consistentSnapshot", "filesystemWrites", "currentLibraryChanged", "restoreReady", "checkedAtEpochMs", "expiresAtEpochMs"] as const;
function validReport(v: unknown, selectedPath: string, now = Date.now()): v is KnowledgeCandidateCheckReport {
    if (!v || typeof v !== "object" || !exact(v, reportKeys))
        return false;
    const x = v as KnowledgeCandidateCheckReport;
    if (!uuidV4(x.reportId) || !candidatePath(x.candidatePath) || x.candidatePath !== selectedPath || x.schemaVersion !== 1 || x.scope !== "selectedKnowledgeCandidate" || !uuidV4(x.stagePlanId) || x.stagePlanId !== stageIdFromPath(x.candidatePath) || !sha(x.sourcePackageSha256) || !sha(x.manifestSha256) || !sha(x.candidateInventorySha256)
        || !integer(x.candidateFileCount) || x.candidateFileCount < 2 || x.candidateFileCount > KNOWLEDGE_CANDIDATE_CHECK_LIMITS.candidateFiles || !integer(x.candidateByteSize) || x.candidateByteSize <= 0 || x.candidateByteSize > KNOWLEDGE_CANDIDATE_CHECK_LIMITS.candidateBytes || !integer(x.itemCount) || !integer(x.revisionCount) || !integer(x.folderCount) || x.itemCount > 2000 || x.revisionCount > x.itemCount * 32 || (x.itemCount === 0 ? x.revisionCount !== 0 || x.candidateFileCount !== 2 : x.revisionCount < x.itemCount || x.candidateFileCount < 3 || x.candidateFileCount > x.revisionCount * 2 + 2) || x.folderCount > 128 || !validCurrent(x.currentLibrary) || !exactLimits(x.limits)
        || x.candidateStructureVerified !== true || x.candidateContentsVerified !== true || x.privatePermissionsVerified !== true || x.sourcePackageHashVerified !== false || x.candidateAuthenticityVerified !== false || x.currentLibraryResourcesVerified !== false || x.comparisonScope !== "manifestIdentityAndMetadataOnly" || x.consistentSnapshot !== false || x.filesystemWrites !== false || x.currentLibraryChanged !== false || x.restoreReady !== false || !time(x.checkedAtEpochMs) || !time(x.expiresAtEpochMs) || x.checkedAtEpochMs > now || x.expiresAtEpochMs <= now || x.expiresAtEpochMs - x.checkedAtEpochMs !== TTL)
        return false;
    if (x.currentLibrary.state !== "checked")
        return x.conflicts === null;
    if (x.currentLibrary.itemCount! > 2000 || x.currentLibrary.revisionCount! > x.currentLibrary.itemCount! * 32 || (x.currentLibrary.itemCount === 0 ? x.currentLibrary.revisionCount !== 0 : x.currentLibrary.revisionCount! < x.currentLibrary.itemCount!) || x.currentLibrary.folderCount! > 128)
        return false;
    return validConflicts(x.conflicts) && x.conflicts.candidateOnlyItems + x.conflicts.identicalItems + x.conflicts.changedItems === x.itemCount && x.conflicts.currentOnlyItems + x.conflicts.identicalItems + x.conflicts.changedItems === x.currentLibrary.itemCount && x.conflicts.candidateOnlyFolders + x.conflicts.identicalFolders + x.conflicts.changedFolders === x.folderCount && x.conflicts.currentOnlyFolders + x.conflicts.identicalFolders + x.conflicts.changedFolders === x.currentLibrary.folderCount;
}
const sameSummary = (a: KnowledgeCandidateCheckReport, b: KnowledgeCandidateCheckReport) => a.candidatePath === b.candidatePath && a.sourcePackageSha256 === b.sourcePackageSha256 && a.manifestSha256 === b.manifestSha256 && a.candidateInventorySha256 === b.candidateInventorySha256 && a.candidateFileCount === b.candidateFileCount && a.candidateByteSize === b.candidateByteSize && a.itemCount === b.itemCount && a.revisionCount === b.revisionCount && a.folderCount === b.folderCount && a.currentLibrary.manifestSha256 === b.currentLibrary.manifestSha256 && a.currentLibrary.itemCount === b.currentLibrary.itemCount && a.currentLibrary.revisionCount === b.currentLibrary.revisionCount && a.currentLibrary.folderCount === b.currentLibrary.folderCount && conflictKeys.every((key) => a.conflicts?.[key] === b.conflicts?.[key]);
function validRecheck(v: unknown, old: KnowledgeCandidateCheckReport, now = Date.now()): v is KnowledgeCandidateRecheck {
    if (!v || typeof v !== "object" || !exact(v, ["report", "comparison"]))
        return false;
    const x = v as KnowledgeCandidateRecheck;
    return validReport(x.report, old.candidatePath, now) && x.report.reportId !== old.reportId && x.report.stagePlanId === old.stagePlanId && (x.comparison === "changed" || x.comparison === "inconclusive" || (x.comparison === "unchanged" && old.currentLibrary.state === "checked" && x.report.currentLibrary.state === "checked" && sameSummary(x.report, old)));
}
export function KnowledgeCandidateCheckPanel({ gateway, enabled, disabled = false, refreshKey }: KnowledgeCandidateCheckPanelProps) {
    const { locale, t } = useI18n(knowledgeCandidateMessages);
    const usable = enabled && !disabled;
    const [path, setPath] = useState<string | null>(null);
    const [report, setReport] = useState<KnowledgeCandidateCheckReport | null>(null);
    const [comparison, setComparison] = useState<KnowledgeCandidateRecheck["comparison"] | null>(null);
    const [busy, setBusy] = useState<"selecting" | "inspecting" | "rechecking" | null>(null);
    const [error, setError] = useState("");
    const contextRef = useRef({ gateway, enabled, disabled, refreshKey, path });
    contextRef.current = { gateway, enabled, disabled, refreshKey, path };
    const pathRef = useRef(path);
    pathRef.current = path;
    const reportRef = useRef<KnowledgeCandidateCheckReport | null>(null);
    const bindingRef = useRef<{
        report: KnowledgeCandidateCheckReport;
        context: typeof contextRef.current;
    } | null>(null);
    const generation = useRef(0);
    const busyRef = useRef(false);
    const same = (c: typeof contextRef.current) => { const x = contextRef.current; return x.gateway === c.gateway && x.enabled === c.enabled && x.disabled === c.disabled && x.refreshKey === c.refreshKey && x.path === c.path; };
    const discard = (r: KnowledgeCandidateCheckReport | null, g?: KnowledgeCandidateCheckGateway) => { if (r && g)
        void g.discardKnowledgeCandidateCheck(r.reportId).catch(() => undefined); };
    const current = usable && reportRef.current === report && bindingRef.current?.report === report && bindingRef.current && same(bindingRef.current.context) && pathRef.current === path ? report : null;
    function clear() { const old = reportRef.current; discard(old, bindingRef.current?.context.gateway); reportRef.current = null; bindingRef.current = null; generation.current += 1; setReport(null); setComparison(null); setError(""); }
    useEffect(() => { clear(); busyRef.current = false; setPath(null); setBusy(null); return () => { discard(reportRef.current, bindingRef.current?.context.gateway); reportRef.current = null; bindingRef.current = null; generation.current += 1; busyRef.current = false; }; }, [gateway, enabled, disabled, refreshKey]);
    useEffect(() => { if (!report)
        return; const timer = window.setTimeout(() => { if (reportRef.current !== report)
        return; discard(report, bindingRef.current?.context.gateway); reportRef.current = null; bindingRef.current = null; setReport(null); setComparison(null); setError("清单已过期，请重新选择并检查候选目录。"); }, Math.max(0, report.expiresAtEpochMs - Date.now())); return () => window.clearTimeout(timer); }, [report?.reportId, report?.expiresAtEpochMs]);
    async function select() { const live = contextRef.current; if (!live.enabled || live.disabled || live.gateway !== gateway || !usable || busyRef.current)
        return; clear(); const ctx = { ...contextRef.current }; const request = ++generation.current; busyRef.current = true; setBusy("selecting"); try {
        const next = await ctx.gateway.selectKnowledgeCandidateDirectory();
        if (request !== generation.current || !same(ctx) || !contextRef.current.enabled || contextRef.current.disabled || contextRef.current.gateway !== gateway)
            return;
        if (next !== null && !candidatePath(next))
            throw new Error("invalid");
        if (next !== null) {
            contextRef.current.path = next;
            setPath(next);
        }
    }
    catch {
        if (request === generation.current && same(ctx))
            setError("无法选择候选目录，请重新选择。");
    }
    finally {
        if (request === generation.current && contextRef.current.gateway === ctx.gateway) {
            busyRef.current = false;
            setBusy(null);
        }
    } }
    async function inspect() { const selected = path; const live = contextRef.current; const ctx = { ...live }; if (!live.enabled || live.disabled || live.gateway !== gateway || !usable || busyRef.current || !selected || selected !== pathRef.current || ctx.path !== selected || !candidatePath(selected))
        return; clear(); const request = ++generation.current; busyRef.current = true; setBusy("inspecting"); try {
        const next: unknown = await ctx.gateway.inspectKnowledgeCandidate(selected);
        if (request !== generation.current || !same(ctx) || !contextRef.current.enabled || contextRef.current.disabled || contextRef.current.gateway !== gateway || pathRef.current !== selected) {
            if (next && typeof next === "object" && uuidV4((next as Partial<KnowledgeCandidateCheckReport>).reportId))
                discard(next as KnowledgeCandidateCheckReport, ctx.gateway);
            return;
        }
        if (!validReport(next, selected)) {
            if (next && typeof next === "object" && uuidV4((next as Partial<KnowledgeCandidateCheckReport>).reportId))
                discard(next as KnowledgeCandidateCheckReport, ctx.gateway);
            throw new Error("invalid");
        }
        reportRef.current = next;
        bindingRef.current = { report: next, context: ctx };
        setReport(next);
    }
    catch {
        if (request === generation.current && same(ctx))
            setError("候选目录清单无效或超出固定限制。");
    }
    finally {
        if (request === generation.current && same(ctx)) {
            busyRef.current = false;
            setBusy(null);
        }
    } }
    async function recheck() { const old = current; const binding = bindingRef.current; const ctx = { ...contextRef.current }; if (!usable || !contextRef.current.enabled || contextRef.current.disabled || contextRef.current.gateway !== gateway || busyRef.current || !old || old !== report || old !== reportRef.current || !binding || binding.report !== old || !same(binding.context) || !same(ctx) || pathRef.current !== path || ctx.path !== path || old.expiresAtEpochMs <= Date.now())
        return; reportRef.current = null; bindingRef.current = null; setReport(null); setComparison(null); setError(""); const request = ++generation.current; busyRef.current = true; setBusy("rechecking"); try {
        const next: unknown = await ctx.gateway.recheckKnowledgeCandidate(old.reportId);
        if (request !== generation.current || !same(ctx)) {
            if (next && typeof next === "object" && typeof (next as Partial<KnowledgeCandidateCheckReport>).reportId === "string" && uuidV4(((next as Partial<KnowledgeCandidateCheckReport>).reportId)))
                discard(next as KnowledgeCandidateCheckReport, ctx.gateway);
            else if (next && typeof next === "object" && (next as Partial<KnowledgeCandidateRecheck>).report && typeof ((next as Partial<KnowledgeCandidateRecheck>).report as Partial<KnowledgeCandidateCheckReport>).reportId === "string" && uuidV4(((next as Partial<KnowledgeCandidateRecheck>).report as Partial<KnowledgeCandidateCheckReport>).reportId))
                discard((next as KnowledgeCandidateRecheck).report, ctx.gateway);
            return;
        }
        if (!validRecheck(next, old)) {
            if (next && typeof next === "object" && (next as Partial<KnowledgeCandidateRecheck>).report && uuidV4(((next as Partial<KnowledgeCandidateRecheck>).report as Partial<KnowledgeCandidateCheckReport>).reportId))
                discard((next as KnowledgeCandidateRecheck).report, ctx.gateway);
            throw new Error("invalid");
        }
        const value = next as KnowledgeCandidateRecheck;
        reportRef.current = value.report;
        bindingRef.current = { report: value.report, context: ctx };
        setReport(value.report);
        setComparison(value.comparison);
    }
    catch {
        if (request === generation.current && same(ctx))
            setError("重新核对失败；旧清单已消耗，请重新检查候选目录。");
    }
    finally {
        if (request === generation.current && same(ctx)) {
            busyRef.current = false;
            setBusy(null);
        }
    } }
    const checked = current?.currentLibrary.state === "checked";
    const conflicts = checked ? current?.conflicts : null;
    return <section className="operation-plan" aria-label={t("候选目录核验")} aria-busy={busy !== null}>
        <h4>{t("候选目录核验")}</h4>
        <p className="publish-muted">{t("只读取候选目录结构、文件内容摘要和当前资料库清单元数据；不会恢复、替换或写入当前资料库。")}</p>
        <p className="publish-warning">{t("候选目录仅完成结构、内容与私有权限核验；来源包哈希、候选真实性、当前资源和一致快照仍未证明。")}</p>
        <button type="button" onClick={() => void select()} disabled={!usable || busy !== null}>{t("选择候选目录")}</button>
        {path && <p>{t("候选路径：{candidatePath}", { candidatePath: path })}</p>}
        {path && <button type="button" onClick={() => void inspect()} disabled={!usable || busy !== null}>{t("检查候选目录")}</button>}
        {busy === "selecting" && <p role="status">{t("正在选择候选目录…")}</p>}
        {busy === "inspecting" && <p role="status">{t("正在读取候选目录…")}</p>}
        {busy === "rechecking" && <p role="status">{t("正在重新核对候选目录…")}</p>}
        {error && <p role="alert" className="publish-warning">{t(error)}</p>}
        {current && <div className="operation-plan">
            <p><strong>{t("候选目录清单（一次性，5 分钟内有效）")}</strong></p>
            <p>{t("候选路径：{candidatePath}", { candidatePath: current.candidatePath })}</p>
            <p>{t("资料项：{itemCount}；历史修订：{revisionCount}；文件夹：{folderCount}；文件：{fileCount}；大小：{byteSize} 字节", { itemCount: current.itemCount.toLocaleString(locale), revisionCount: current.revisionCount.toLocaleString(locale), folderCount: current.folderCount.toLocaleString(locale), fileCount: current.candidateFileCount.toLocaleString(locale), byteSize: current.candidateByteSize.toLocaleString(locale) })}</p>
            <p>{t("候选清单 SHA-256：{candidateInventorySha256}", { candidateInventorySha256: current.candidateInventorySha256 })}</p>
            <p>{t("当前资料库状态：{state}{unavailable}", { state: t(currentStateLabels[current.currentLibrary.state]), unavailable: checked ? "" : t("，当前统计不可用") })}</p>
            {checked && current.currentLibrary.manifestSha256 && <p>{t("当前资料库清单 SHA-256：{manifestSha256}；资料项：{itemCount}；历史修订：{revisionCount}；文件夹：{folderCount}", { manifestSha256: current.currentLibrary.manifestSha256, itemCount: current.currentLibrary.itemCount!.toLocaleString(locale), revisionCount: current.currentLibrary.revisionCount!.toLocaleString(locale), folderCount: current.currentLibrary.folderCount!.toLocaleString(locale) })}</p>}
            {conflicts && <div>
                <p>{t("清单冲突摘要（同一 ID 的完整保存元数据或历史不同也算变化）：")}</p>
                <p>{t("资料项：候选新增 {candidateOnly}；当前独有 {currentOnly}；相同 {identical}；已变化 {changed}", { candidateOnly: conflicts.candidateOnlyItems.toLocaleString(locale), currentOnly: conflicts.currentOnlyItems.toLocaleString(locale), identical: conflicts.identicalItems.toLocaleString(locale), changed: conflicts.changedItems.toLocaleString(locale) })}</p>
                <p>{t("文件夹：候选新增 {candidateOnly}；当前独有 {currentOnly}；相同 {identical}；已变化 {changed}", { candidateOnly: conflicts.candidateOnlyFolders.toLocaleString(locale), currentOnly: conflicts.currentOnlyFolders.toLocaleString(locale), identical: conflicts.identicalFolders.toLocaleString(locale), changed: conflicts.changedFolders.toLocaleString(locale) })}</p>
            </div>}
            {comparison && <p role="status">{t("重新核对结果：{comparison}", { comparison: t(comparison === "unchanged" ? "未变化" : comparison === "changed" ? "已变化" : "无法确定") })}</p>}
            <p>{t("仅比较清单身份与元数据；不验证当前资料库资源，不选择恢复策略，也不证明来源包、候选真实性、一致快照或可恢复性。")}</p>
            <button type="button" onClick={() => void recheck()} disabled={!usable || busy !== null}>{t("一次性重新核对")}</button>
            <button type="button" onClick={clear} disabled={busy !== null}>{t("取消清单")}</button>
        </div>}
    </section>;
}
