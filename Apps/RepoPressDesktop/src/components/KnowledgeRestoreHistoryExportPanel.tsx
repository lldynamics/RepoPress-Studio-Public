import { useEffect, useRef, useState } from "react";
import { KNOWLEDGE_BACKUP_EXCLUSIONS } from "../contracts/knowledgeBackup";
import type { KnowledgeRestoreArchiveEntry, KnowledgeRestoreTerminalPhase } from "../contracts/knowledgeRestoreArchive";
import type {
  KnowledgeRestoreHistoryExportGateway,
  KnowledgeRestoreHistoryExportPlan,
  KnowledgeRestoreHistoryExportReceipt,
  KnowledgeRestoreHistoryExportStatus,
} from "../contracts/knowledgeRestoreHistoryExport";

export interface KnowledgeRestoreHistoryExportPanelProps {
  gateway: KnowledgeRestoreHistoryExportGateway;
  enabled: boolean;
  disabled?: boolean;
  refreshKey?: number;
}

const TTL_MS = 300_000;
const HISTORY_LIMIT = 4;
const MAX_SNAPSHOT_FILES = 2_049;
const MAX_SNAPSHOT_BYTES = 66 * 1024 * 1024;
const MAX_ITEMS = 2_000;
const MAX_RESOURCE_FILES = 1_024;
const MAX_RESOURCE_BYTES = 32 * 1024 * 1024;
const MAX_PACKAGE_BYTES = 48 * 1024 * 1024;
const MAX_TIME = 8.64e15;
const statusKeys = ["schemaVersion", "scope", "state", "history", "historyLimit", "libraryAccessBlocked", "filesystemWrites"] as const;
const entryKeys = ["transactionId", "phase", "previousManifestSha256", "projectedManifestSha256", "snapshotManifestSha256", "snapshotPresent", "snapshotFileCount", "snapshotByteSize", "archivedAtEpochMs"] as const;
const planKeys = ["schemaVersion", "scope", "planId", "selected", "destinationPath", "byteSize", "sha256", "manifestSha256", "sourceManifestSha256", "itemCount", "revisionCount", "bodyFileCount", "archiveFileCount", "resourceByteSize", "exclusions", "requiresSensitivePlaintextConsent", "currentLibraryChanged", "sourceHistoryChanged", "restoreReady", "includesCredentialStores", "includesCompletedOperations", "externalReferencesIncluded", "consistentSnapshot", "checkedAtEpochMs", "expiresAtEpochMs"] as const;
const receiptKeys = ["schemaVersion", "scope", "planId", "selected", "destinationPath", "byteSize", "sha256", "manifestSha256", "sourceManifestSha256", "sourceRevalidated", "contentsVerified", "privatePermissionsVerified", "currentLibraryChanged", "sourceHistoryChanged", "restoreReady", "completedAtEpochMs"] as const;
const terminalPhases: KnowledgeRestoreTerminalPhase[] = ["committed", "rolledBack", "cancelled"];

const record = (value: unknown): value is Record<string, unknown> => value !== null && typeof value === "object" && !Array.isArray(value);
const exactKeys = (value: Record<string, unknown>, keys: readonly string[]) => {
  const actual = Object.keys(value);
  return actual.length === keys.length && keys.every((key) => Object.prototype.hasOwnProperty.call(value, key));
};
const uuidV4 = (value: unknown): value is string => typeof value === "string"
  && /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(value);
const sha256 = (value: unknown): value is string => typeof value === "string" && /^[0-9a-f]{64}$/.test(value);
const safeInt = (value: unknown): value is number => typeof value === "number" && Number.isSafeInteger(value);
const inRange = (value: unknown, minimum: number, maximum: number): value is number => safeInt(value) && value >= minimum && value <= maximum;
const validTime = (value: unknown): value is number => safeInt(value) && value > 0 && value <= MAX_TIME;
const snapshot = (value: unknown) => JSON.stringify(value);
const copy = <T,>(value: T): T => JSON.parse(JSON.stringify(value)) as T;
const absoluteJsonPath = (value: unknown): value is string => {
  if (typeof value !== "string" || !value.startsWith("/") || !value.endsWith(".json") || value.includes("\0")) return false;
  return value.split("/").every((part) => part !== "." && part !== "..");
};

function validSnapshotFields(value: {
  snapshotPresent: unknown;
  snapshotManifestSha256: unknown;
  snapshotFileCount: unknown;
  snapshotByteSize: unknown;
}) {
  if (typeof value.snapshotPresent !== "boolean") return false;
  if (!value.snapshotPresent) {
    return value.snapshotManifestSha256 === null && value.snapshotFileCount === 0 && value.snapshotByteSize === 0;
  }
  return sha256(value.snapshotManifestSha256)
    && inRange(value.snapshotFileCount, 1, MAX_SNAPSHOT_FILES)
    && inRange(value.snapshotByteSize, 1, MAX_SNAPSHOT_BYTES);
}

function validEntry(value: unknown, now: number): value is KnowledgeRestoreArchiveEntry {
  if (!record(value) || !exactKeys(value, entryKeys)) return false;
  const entry = value as unknown as KnowledgeRestoreArchiveEntry;
  return uuidV4(entry.transactionId) && terminalPhases.includes(entry.phase)
    && sha256(entry.previousManifestSha256) && sha256(entry.projectedManifestSha256)
    && validSnapshotFields(entry) && validTime(entry.archivedAtEpochMs) && entry.archivedAtEpochMs <= now;
}

function validHistory(value: unknown, now: number): value is KnowledgeRestoreArchiveEntry[] {
  if (!Array.isArray(value) || value.length > HISTORY_LIMIT || !value.every((entry) => validEntry(entry, now))) return false;
  return new Set(value.map((entry) => entry.transactionId)).size === value.length;
}

function validStatus(value: unknown, now = Date.now()): value is KnowledgeRestoreHistoryExportStatus {
  if (!record(value) || !exactKeys(value, statusKeys)) return false;
  const status = value as unknown as KnowledgeRestoreHistoryExportStatus;
  if (status.schemaVersion !== 1 || status.scope !== "knowledgeRestoreHistoryExportStatus"
    || status.historyLimit !== HISTORY_LIMIT || status.filesystemWrites !== false
    || typeof status.libraryAccessBlocked !== "boolean" || !validHistory(status.history, now)) return false;
  if (status.state === "none") return status.history.length === 0 && !status.libraryAccessBlocked;
  if (status.state === "ready") return status.history.length >= 1 && !status.libraryAccessBlocked;
  if (status.state === "blocked" || status.state === "unavailable") {
    return status.history.length === 0 && (status.state === "blocked" || status.libraryAccessBlocked);
  }
  return false;
}

function exactExclusions(value: unknown): value is string[] {
  return Array.isArray(value) && value.length === KNOWLEDGE_BACKUP_EXCLUSIONS.length
    && value.every((item) => typeof item === "string") && new Set(value).size === KNOWLEDGE_BACKUP_EXCLUSIONS.length
    && KNOWLEDGE_BACKUP_EXCLUSIONS.every((item) => value.includes(item));
}

function validPlan(
  value: unknown,
  selected: KnowledgeRestoreArchiveEntry,
  destinationPath: string,
  now = Date.now(),
): value is KnowledgeRestoreHistoryExportPlan {
  if (!record(value) || !exactKeys(value, planKeys) || !selected.snapshotPresent) return false;
  const plan = value as unknown as KnowledgeRestoreHistoryExportPlan;
  const resourceCount = plan.bodyFileCount + plan.archiveFileCount;
  return plan.schemaVersion === 1 && plan.scope === "knowledgeRestoreHistoryExportPlan" && uuidV4(plan.planId)
    && validEntry(plan.selected, now) && snapshot(plan.selected) === snapshot(selected)
    && plan.destinationPath === destinationPath && absoluteJsonPath(plan.destinationPath)
    && inRange(plan.itemCount, 0, MAX_ITEMS) && inRange(plan.revisionCount, 0, MAX_ITEMS * 32)
    && (plan.itemCount === 0 ? plan.revisionCount === 0 : plan.revisionCount >= plan.itemCount)
    && inRange(plan.bodyFileCount, 0, MAX_RESOURCE_FILES) && plan.bodyFileCount <= plan.revisionCount
    && inRange(plan.archiveFileCount, 0, MAX_RESOURCE_FILES) && plan.archiveFileCount <= plan.revisionCount
    && resourceCount <= MAX_RESOURCE_FILES && resourceCount + 1 === selected.snapshotFileCount
    && (plan.itemCount === 0 ? plan.bodyFileCount === 0 : plan.bodyFileCount >= 1)
    && inRange(plan.resourceByteSize, 0, MAX_RESOURCE_BYTES) && (resourceCount > 0 || plan.resourceByteSize === 0)
    && inRange(plan.byteSize, 1, MAX_PACKAGE_BYTES) && plan.byteSize >= plan.resourceByteSize
    && sha256(plan.sha256) && sha256(plan.manifestSha256) && sha256(plan.sourceManifestSha256)
    && plan.sourceManifestSha256 === selected.snapshotManifestSha256
    && exactExclusions(plan.exclusions) && plan.requiresSensitivePlaintextConsent === true
    && plan.currentLibraryChanged === false && plan.sourceHistoryChanged === false && plan.restoreReady === false
    && plan.includesCredentialStores === false && plan.includesCompletedOperations === false
    && plan.externalReferencesIncluded === false && plan.consistentSnapshot === false
    && validTime(plan.checkedAtEpochMs) && validTime(plan.expiresAtEpochMs)
    && plan.checkedAtEpochMs <= now && plan.expiresAtEpochMs > now
    && plan.expiresAtEpochMs - plan.checkedAtEpochMs === TTL_MS;
}

function validReceipt(value: unknown, plan: KnowledgeRestoreHistoryExportPlan, now = Date.now()): value is KnowledgeRestoreHistoryExportReceipt {
  if (!record(value) || !exactKeys(value, receiptKeys)) return false;
  const receipt = value as unknown as KnowledgeRestoreHistoryExportReceipt;
  return receipt.schemaVersion === 1 && receipt.scope === "knowledgeRestoreHistoryExportReceipt"
    && receipt.planId === plan.planId && validEntry(receipt.selected, now)
    && snapshot(receipt.selected) === snapshot(plan.selected) && receipt.destinationPath === plan.destinationPath
    && receipt.byteSize === plan.byteSize && receipt.sha256 === plan.sha256
    && receipt.manifestSha256 === plan.manifestSha256 && receipt.sourceManifestSha256 === plan.sourceManifestSha256
    && sha256(receipt.sha256) && sha256(receipt.manifestSha256) && sha256(receipt.sourceManifestSha256)
    && receipt.sourceRevalidated === true && receipt.contentsVerified === true && receipt.privatePermissionsVerified === true
    && receipt.currentLibraryChanged === false && receipt.sourceHistoryChanged === false && receipt.restoreReady === false
    && validTime(receipt.completedAtEpochMs) && receipt.completedAtEpochMs >= plan.checkedAtEpochMs
    && receipt.completedAtEpochMs <= now;
}

const recognizablePlanId = (value: unknown) => record(value) && uuidV4(value.planId);

type Context = {
  gateway: KnowledgeRestoreHistoryExportGateway;
  enabled: boolean;
  disabled: boolean;
  refreshKey: number | undefined;
};
type StatusBinding = { value: KnowledgeRestoreHistoryExportStatus; snapshot: string; context: Context };
type DestinationBinding = { path: string; transactionId: string; status: StatusBinding; context: Context };
type PlanBinding = { value: KnowledgeRestoreHistoryExportPlan; snapshot: string; destination: DestinationBinding; context: Context };

const phaseLabel: Record<KnowledgeRestoreTerminalPhase, string> = {
  committed: "已完成", rolledBack: "已回滚", cancelled: "已取消",
};
const stateLabel: Record<KnowledgeRestoreHistoryExportStatus["state"], string> = {
  none: "没有恢复历史",
  ready: "可选择完整历史快照",
  blocked: "历史状态不完整，已阻止导出",
  unavailable: "历史导出状态不可用",
};
const exclusionLabel: Record<typeof KNOWLEDGE_BACKUP_EXCLUSIONS[number], string> = {
  credentialStores: "凭据存储",
  otherWorkspaceSources: "其他工作区来源",
  repositoryFiles: "仓库当前文件",
  externalReferences: "外部引用内容",
  unreferencedFiles: "未引用文件",
  completedOperations: "持久操作回执",
  runtimeState: "运行时状态",
  sourcePdfFiles: "PDF 原文件",
  attachmentFiles: "附件原文件",
};

export function KnowledgeRestoreHistoryExportPanel({ gateway, enabled, disabled = false, refreshKey }: KnowledgeRestoreHistoryExportPanelProps) {
  const [status, setStatus] = useState<KnowledgeRestoreHistoryExportStatus | null>(null);
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [destinationPath, setDestinationPath] = useState<string | null>(null);
  const [plan, setPlan] = useState<KnowledgeRestoreHistoryExportPlan | null>(null);
  const [receipt, setReceipt] = useState<KnowledgeRestoreHistoryExportReceipt | null>(null);
  const [consent, setConsent] = useState(false);
  const [busy, setBusy] = useState<"inspecting" | "selecting" | "planning" | "exporting" | null>(null);
  const [error, setError] = useState("");
  const context: Context = { gateway, enabled, disabled, refreshKey };
  const contextRef = useRef(context); contextRef.current = context;
  const statusRef = useRef<StatusBinding | null>(null);
  const selectedIdRef = useRef<string | null>(null);
  const destinationRef = useRef<DestinationBinding | null>(null);
  const planRef = useRef<PlanBinding | null>(null);
  const receiptRef = useRef<{ value: KnowledgeRestoreHistoryExportReceipt; context: Context } | null>(null);
  const consentRef = useRef(false);
  const busyRef = useRef(false);
  const generation = useRef(0);
  const usable = enabled && !disabled;

  const same = (candidate: Context) => {
    const current = contextRef.current;
    return candidate.gateway === current.gateway && candidate.enabled === current.enabled
      && candidate.disabled === current.disabled && candidate.refreshKey === current.refreshKey;
  };
  const discardId = (planId: string, sourceGateway: KnowledgeRestoreHistoryExportGateway) => {
    void sourceGateway.discardKnowledgeRestoreHistoryExport(planId).catch(() => undefined);
  };
  const clearPlan = () => {
    const bound = planRef.current;
    planRef.current = null;
    if (bound) discardId(bound.value.planId, bound.context.gateway);
    setPlan(null); consentRef.current = false; setConsent(false);
  };
  const clearCapability = () => {
    clearPlan(); statusRef.current = null; selectedIdRef.current = null; destinationRef.current = null; receiptRef.current = null;
    setStatus(null); setSelectedId(null); setDestinationPath(null); setReceipt(null);
  };

  const statusBinding = statusRef.current;
  const shownStatus = usable && status && statusBinding?.value === status && same(statusBinding.context)
    && snapshot(status) === statusBinding.snapshot && validStatus(status) ? status : null;
  const shownSelected = shownStatus?.history.find((entry) => entry.transactionId === selectedId && entry.snapshotPresent) ?? null;
  const destinationBinding = destinationRef.current;
  const shownDestination = shownSelected && destinationPath && destinationBinding?.path === destinationPath
    && destinationBinding.transactionId === shownSelected.transactionId && destinationBinding.status === statusBinding
    && same(destinationBinding.context) && absoluteJsonPath(destinationPath) ? destinationPath : null;
  const planBinding = planRef.current;
  const shownPlan = shownDestination && shownSelected && plan && planBinding?.value === plan
    && planBinding.destination === destinationBinding && same(planBinding.context)
    && snapshot(plan) === planBinding.snapshot && validPlan(plan, shownSelected, shownDestination) ? plan : null;
  const shownReceipt = usable && receipt && receiptRef.current?.value === receipt && same(receiptRef.current.context) ? receipt : null;

  useEffect(() => {
    const old = planRef.current;
    planRef.current = null;
    if (old) discardId(old.value.planId, old.context.gateway);
    statusRef.current = null; selectedIdRef.current = null; destinationRef.current = null; receiptRef.current = null;
    consentRef.current = false; generation.current += 1; busyRef.current = false;
    setStatus(null); setSelectedId(null); setDestinationPath(null); setPlan(null); setReceipt(null);
    setConsent(false); setBusy(null); setError("");
    return () => {
      const current = planRef.current;
      planRef.current = null;
      if (current) discardId(current.value.planId, current.context.gateway);
      statusRef.current = null; selectedIdRef.current = null; destinationRef.current = null; receiptRef.current = null;
      consentRef.current = false; generation.current += 1; busyRef.current = false;
    };
  }, [gateway, enabled, disabled, refreshKey]);

  useEffect(() => {
    const binding = planRef.current;
    if (!binding || binding.value !== plan) return;
    const timer = window.setTimeout(() => {
      if (planRef.current !== binding) return;
      clearCapability(); generation.current += 1;
      setError("历史快照导出计划已过期，请重新检查、选择并准备。");
    }, Math.max(0, binding.value.expiresAtEpochMs - Date.now()));
    return () => window.clearTimeout(timer);
  }, [plan?.planId, plan?.expiresAtEpochMs]);

  async function inspect() {
    const requestContext = { ...contextRef.current };
    if (!same(context) || !requestContext.enabled || requestContext.disabled || busyRef.current) return;
    clearCapability(); generation.current += 1; setError("");
    const request = ++generation.current; busyRef.current = true; setBusy("inspecting");
    try {
      const next: unknown = await requestContext.gateway.inspectKnowledgeRestoreHistoryExport();
      if (request !== generation.current || !same(requestContext)) return;
      if (!validStatus(next)) throw new Error("invalid history export status");
      const accepted = copy(next);
      if (!validStatus(accepted)) throw new Error("invalid copied history export status");
      const binding: StatusBinding = { value: accepted, snapshot: snapshot(accepted), context: requestContext };
      statusRef.current = binding; setStatus(accepted);
    } catch {
      if (request === generation.current && same(requestContext)) {
        setError("无法核验恢复历史；读取失败不表示快照可导出。请重新手动检查，系统不会自动重试。");
      }
    } finally {
      if (request === generation.current) { busyRef.current = false; setBusy(null); }
    }
  }

  function selectEntry(transactionId: string) {
    const currentStatus = shownStatus;
    if (!currentStatus || busyRef.current || !usable || !same(context)) return;
    const selected = currentStatus.history.find((entry) => entry.transactionId === transactionId);
    if (!selected?.snapshotPresent) return;
    clearPlan(); generation.current += 1; destinationRef.current = null; receiptRef.current = null;
    selectedIdRef.current = transactionId; setSelectedId(transactionId); setDestinationPath(null); setReceipt(null); setError("");
  }

  async function chooseDestination() {
    const binding = statusRef.current;
    const currentSelected = shownSelected;
    const requestContext = { ...contextRef.current };
    if (!binding || !currentSelected || selectedIdRef.current !== currentSelected.transactionId
      || !same(context) || !same(requestContext) || !requestContext.enabled || requestContext.disabled || busyRef.current) return;
    clearPlan(); generation.current += 1; destinationRef.current = null; receiptRef.current = null;
    setDestinationPath(null); setReceipt(null); setError("");
    const request = ++generation.current; busyRef.current = true; setBusy("selecting");
    try {
      const next: unknown = await requestContext.gateway.selectKnowledgeRestoreHistoryExportDestination();
      if (request !== generation.current || !same(requestContext) || statusRef.current !== binding
        || selectedIdRef.current !== currentSelected.transactionId) return;
      if (next === null) return;
      if (!absoluteJsonPath(next)) throw new Error("invalid destination");
      const destination: DestinationBinding = { path: next, transactionId: currentSelected.transactionId, status: binding, context: requestContext };
      destinationRef.current = destination; setDestinationPath(next);
    } catch {
      if (request === generation.current && same(requestContext)) {
        setError("无法选择新的历史快照 JSON 资料包路径；请选择新的绝对小写 .json 文件路径。");
      }
    } finally {
      if (request === generation.current) { busyRef.current = false; setBusy(null); }
    }
  }

  async function prepare() {
    const currentSelected = shownSelected;
    const currentDestination = destinationRef.current;
    const requestContext = { ...contextRef.current };
    if (!currentSelected || !shownDestination || !currentDestination || !statusRef.current
      || selectedIdRef.current !== currentSelected.transactionId || currentDestination.status !== statusRef.current
      || !same(context) || !same(requestContext) || !requestContext.enabled || requestContext.disabled || busyRef.current) return;
    clearPlan(); receiptRef.current = null; setReceipt(null); setError("");
    const request = ++generation.current; busyRef.current = true; setBusy("planning");
    try {
      const next: unknown = await requestContext.gateway.planKnowledgeRestoreHistoryExport(currentSelected.transactionId, shownDestination);
      if (request !== generation.current || !same(requestContext) || destinationRef.current !== currentDestination
        || selectedIdRef.current !== currentSelected.transactionId) {
        if (recognizablePlanId(next)) discardId((next as { planId: string }).planId, requestContext.gateway);
        return;
      }
      if (!validPlan(next, currentSelected, shownDestination)) {
        if (recognizablePlanId(next)) discardId((next as { planId: string }).planId, requestContext.gateway);
        throw new Error("invalid history export plan");
      }
      const accepted = copy(next);
      if (!validPlan(accepted, currentSelected, shownDestination)) throw new Error("invalid copied history export plan");
      const planBinding: PlanBinding = { value: accepted, snapshot: snapshot(accepted), destination: currentDestination, context: requestContext };
      planRef.current = planBinding; setPlan(accepted);
    } catch {
      if (request === generation.current && same(requestContext)) {
        setError("历史快照 JSON 资料包计划无效；请重新检查、选择历史和新路径。系统不会自动导出或重试。");
      }
    } finally {
      if (request === generation.current) { busyRef.current = false; setBusy(null); }
    }
  }

  async function execute() {
    const binding = planRef.current;
    const requestContext = { ...contextRef.current };
    if (!binding || !shownPlan || shownPlan !== binding.value || !same(context) || !same(requestContext)
      || !requestContext.enabled || requestContext.disabled || busyRef.current || !consent || !consentRef.current
      || snapshot(binding.value) !== binding.snapshot) return;
    const now = Date.now();
    if (now < binding.value.checkedAtEpochMs || now >= binding.value.expiresAtEpochMs
      || !validPlan(binding.value, binding.value.selected, binding.value.destinationPath, now)) {
      clearCapability(); generation.current += 1;
      setError("历史快照导出计划已过期或系统时间已变化，请重新检查、选择并准备。"); return;
    }

    // Consume the one-use UI capability before crossing the gateway boundary.
    planRef.current = null; statusRef.current = null; selectedIdRef.current = null; destinationRef.current = null; receiptRef.current = null;
    setPlan(null); setStatus(null); setSelectedId(null); setDestinationPath(null); setReceipt(null);
    consentRef.current = false; setConsent(false); setError("");
    const request = ++generation.current; busyRef.current = true; setBusy("exporting");
    try {
      const next: unknown = await binding.context.gateway.executeKnowledgeRestoreHistoryExport(binding.value.planId, true);
      if (request !== generation.current || !same(requestContext)) return;
      if (!validReceipt(next, binding.value)) throw new Error("invalid history export receipt");
      const accepted = copy(next);
      if (!validReceipt(accepted, binding.value)) throw new Error("invalid copied history export receipt");
      receiptRef.current = { value: accepted, context: requestContext }; setReceipt(accepted);
    } catch {
      if (request === generation.current && same(requestContext)) {
        setError("历史快照资料包可能已经写入，但完成状态未知；计划已消耗。请重新手动检查并选择新的路径，系统不会自动重试。");
      }
    } finally {
      if (request === generation.current) { busyRef.current = false; setBusy(null); }
    }
  }

  function changeConsent(value: boolean) {
    if (!shownPlan || busyRef.current || !usable || !same(context)) return;
    consentRef.current = value; setConsent(value);
  }

  function abandonPlan() {
    if (!shownPlan || busyRef.current || !usable || !same(context)) return;
    clearPlan(); generation.current += 1; setError("");
  }

  if (!enabled) return null;
  return <section className="operation-plan" aria-label="恢复历史完整快照 JSON 资料包导出" aria-busy={busy !== null}>
    <h4>恢复历史完整快照 JSON 资料包导出</h4>
    <p className="publish-muted">手动检查最多 4 条恢复历史，可选择任意含完整快照的条目导出确认式 JSON 资料包。列表只显示事务 UUID、终态、归档时间、文件数和快照清单 SHA-256，不显示标题、路径、URL 或正文。</p>
    <p className="publish-warning">资料包包含敏感明文；原恢复历史和当前资料库保持不变。仅日志条目不能导出。导出完成后，仍需单独核验资料包、生成候选并准备恢复。</p>
    <p className="publish-muted">导出上限为 1024 个保存资源、32 MiB 资源、2 MiB 清单和 48 MiB JSON 包；超限或存档完整性未知时拒绝导出。请选择与应用数据目录处于同一挂载点的新本地 JSON 路径，其他挂载点和绑定挂载暂不支持。</p>
    <button type="button" onClick={() => void inspect()} disabled={!usable || busy !== null}>检查恢复历史快照</button>
    {busy && <p role="status">{busy === "inspecting" ? "正在只读检查恢复历史…" : busy === "selecting" ? "正在选择新的 JSON 路径…" : busy === "planning" ? "正在准备历史快照导出计划…" : "正在导出并核验 JSON 资料包…"}</p>}
    {error && <p role="alert" className="publish-warning">{error}</p>}

    {shownStatus && <div className="operation-plan">
      <p><strong>只读恢复历史</strong></p>
      <p>状态：{stateLabel[shownStatus.state]}；历史：{shownStatus.history.length}/{shownStatus.historyLimit}；资料库访问：{shownStatus.libraryAccessBlocked ? "已阻止" : "可用"}</p>
      {shownStatus.history.map((entry) => <label key={entry.transactionId}>
        <input type="radio" name="knowledge-restore-history-export" value={entry.transactionId}
          checked={selectedId === entry.transactionId} disabled={!entry.snapshotPresent || busy !== null || !usable}
          onChange={() => selectEntry(entry.transactionId)} />
        事务 UUID：{entry.transactionId}；终态：{phaseLabel[entry.phase]}；归档时间：{entry.archivedAtEpochMs}；文件数：{entry.snapshotFileCount}；快照清单 SHA-256：{entry.snapshotManifestSha256 ?? "无（仅日志，不可导出）"}
      </label>)}
      {shownStatus.state !== "ready" && <p className="publish-muted">当前状态没有可选择的完整历史快照。</p>}
    </div>}

    {shownSelected && <div className="operation-plan">
      <p>已选择事务 UUID：{shownSelected.transactionId}</p>
      <button type="button" onClick={() => void chooseDestination()} disabled={busy !== null || !usable}>选择新的历史快照 JSON 路径</button>
      {shownDestination && <p>目标路径：{shownDestination}</p>}
      {shownDestination && <button type="button" onClick={() => void prepare()} disabled={busy !== null || !usable}>明确预览历史快照资料包</button>}
    </div>}

    {shownPlan && <div className="operation-plan">
      <p><strong>历史快照资料包预览（一次性，5 分钟内有效）</strong></p>
      <p>事务 UUID：{shownPlan.selected.transactionId}；目标路径：{shownPlan.destinationPath}</p>
      <p>资料项：{shownPlan.itemCount}；历史修订：{shownPlan.revisionCount}；正文文件：{shownPlan.bodyFileCount}；存档文件：{shownPlan.archiveFileCount}</p>
      <p>资源字节：{shownPlan.resourceByteSize}；JSON 包字节：{shownPlan.byteSize}；包 SHA-256：{shownPlan.sha256}</p>
      <p>包内清单 SHA-256：{shownPlan.manifestSha256}；来源快照清单 SHA-256：{shownPlan.sourceManifestSha256}</p>
      <p>固定排除：{shownPlan.exclusions.map((item) => exclusionLabel[item as keyof typeof exclusionLabel]).join("、")}</p>
      <label><input type="checkbox" checked={consent} onChange={(event) => changeConsent(event.target.checked)} disabled={busy !== null || !usable} />我已知悉并明确同意将所选恢复历史的敏感资料明文导出到该新 JSON 文件。</label>
      <button type="button" onClick={() => void execute()} disabled={!consent || busy !== null || !usable}>确认并一次性导出历史快照资料包</button>
      <button type="button" onClick={abandonPlan} disabled={busy !== null}>放弃历史快照导出计划</button>
    </div>}

    {shownReceipt && <div className="operation-plan">
      <p role="status">历史完整快照 JSON 资料包已导出并核验，私有文件权限已确认。</p>
      <p>事务 UUID：{shownReceipt.selected.transactionId}；路径：{shownReceipt.destinationPath}；字节：{shownReceipt.byteSize}；SHA-256：{shownReceipt.sha256}</p>
      <p>原恢复历史和当前资料库未改变。下一步须独立选择该资料包，先核验，再生成候选并准备恢复；后续恢复沿用现有身份冲突和权限重置策略。本操作不会自动安装或直接回滚整个资料库。</p>
    </div>}
  </section>;
}
