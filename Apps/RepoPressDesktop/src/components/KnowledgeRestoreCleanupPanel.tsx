import { useEffect, useRef, useState } from "react";
import type {
  KnowledgeRestoreCleanupAction,
  KnowledgeRestoreCleanupGateway,
  KnowledgeRestoreCleanupPlan,
  KnowledgeRestoreCleanupReceipt,
  KnowledgeRestoreCleanupStatus,
} from "../contracts/knowledgeRestoreCleanup";
import type { KnowledgeRestoreArchiveEntry, KnowledgeRestoreTerminalPhase } from "../contracts/knowledgeRestoreArchive";

export interface KnowledgeRestoreCleanupPanelProps {
  gateway: KnowledgeRestoreCleanupGateway;
  enabled: boolean;
  disabled?: boolean;
  refreshKey?: number;
}

const TTL_MS = 300_000;
const HISTORY_LIMIT = 4;
const RECEIPT_LIMIT = 128;
const MAX_SNAPSHOT_FILES = 2_049;
const MAX_SNAPSHOT_BYTES = 66 * 1024 * 1024;
const MAX_CLEANUP_FILES = MAX_SNAPSHOT_FILES + 2;
const MAX_CLEANUP_BYTES = 69 * 1024 * 1024;
const MAX_TIME = 8.64e15;
const statusKeys = ["schemaVersion", "scope", "state", "cleanupId", "selected", "historyCount", "historyLimit", "receiptCount", "receiptLimit", "currentManifestSha256", "remainingFileCount", "remainingByteSize", "canDelete", "canResume", "historySlotReleased", "libraryAccessBlocked", "filesystemWrites"] as const;
const entryKeys = ["transactionId", "phase", "previousManifestSha256", "projectedManifestSha256", "snapshotManifestSha256", "snapshotPresent", "snapshotFileCount", "snapshotByteSize", "archivedAtEpochMs"] as const;
const planKeys = ["schemaVersion", "scope", "planId", "action", "status", "requiresAcknowledgement", "irreversible", "currentLibraryChanged", "deletesSnapshot", "deletesHistory", "preservesAuditReceipt", "reclaimsHistorySlot", "physicalSpaceReclaimedUnknown", "checkedAtEpochMs", "expiresAtEpochMs"] as const;
const receiptKeys = ["schemaVersion", "scope", "planId", "cleanupId", "transactionId", "action", "state", "selected", "removedFileCount", "removedByteSize", "currentLibraryChanged", "historySlotReleased", "auditReceiptPersisted", "physicalSpaceReclaimedUnknown", "completedAtEpochMs"] as const;
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

function validStatus(value: unknown, now = Date.now()): value is KnowledgeRestoreCleanupStatus {
  if (!record(value) || !exactKeys(value, statusKeys)) return false;
  const status = value as unknown as KnowledgeRestoreCleanupStatus;
  if (status.schemaVersion !== 1 || status.scope !== "knowledgeRestoreCleanupStatus"
    || status.historyLimit !== HISTORY_LIMIT || status.receiptLimit !== RECEIPT_LIMIT
    || status.filesystemWrites !== false || typeof status.canDelete !== "boolean"
    || typeof status.canResume !== "boolean" || typeof status.historySlotReleased !== "boolean"
    || typeof status.libraryAccessBlocked !== "boolean") return false;

  if (status.state === "none") {
    return status.cleanupId === null && status.selected === null && status.historyCount === 0
      && inRange(status.receiptCount, 0, RECEIPT_LIMIT)
      && status.currentManifestSha256 === null && status.remainingFileCount === null && status.remainingByteSize === null
      && !status.canDelete && !status.canResume && !status.historySlotReleased && !status.libraryAccessBlocked;
  }
  if (status.state === "eligible") {
    if (status.cleanupId !== null || !validEntry(status.selected, now) || !sha256(status.currentManifestSha256)
      || !inRange(status.receiptCount, 0, RECEIPT_LIMIT)
      || !inRange(status.historyCount, 1, HISTORY_LIMIT) || status.remainingFileCount !== status.selected.snapshotFileCount + 2
      || !inRange(status.remainingByteSize, status.selected.snapshotByteSize, MAX_CLEANUP_BYTES)) return false;
    return status.canDelete === (status.receiptCount < RECEIPT_LIMIT) && !status.canResume
      && !status.historySlotReleased && !status.libraryAccessBlocked;
  }
  if (status.state === "cleaning" || status.state === "cleaned") {
    if (!uuidV4(status.cleanupId) || !validEntry(status.selected, now) || !sha256(status.currentManifestSha256)
      || !inRange(status.receiptCount, 0, RECEIPT_LIMIT)
      || !inRange(status.remainingFileCount, 0, MAX_CLEANUP_FILES)
      || !inRange(status.remainingByteSize, 0, MAX_CLEANUP_BYTES)
      || status.canDelete || !status.canResume || !status.libraryAccessBlocked) return false;
    if (status.state === "cleaning") {
      return status.historySlotReleased
        ? inRange(status.historyCount, 0, HISTORY_LIMIT - 1)
        : inRange(status.historyCount, 1, HISTORY_LIMIT);
    }
    return status.historySlotReleased && inRange(status.historyCount, 0, HISTORY_LIMIT - 1)
      && inRange(status.receiptCount, 1, RECEIPT_LIMIT)
      && status.remainingFileCount === 0 && status.remainingByteSize === 0;
  }
  if (status.state === "blocked" || status.state === "unavailable") {
    return status.cleanupId === null && status.selected === null && status.historyCount === null
      && status.receiptCount === null && status.currentManifestSha256 === null
      && status.remainingFileCount === null && status.remainingByteSize === null
      && !status.canDelete && !status.canResume && !status.historySlotReleased
      && (status.state === "blocked" || status.libraryAccessBlocked);
  }
  return false;
}

function actionAllowed(status: KnowledgeRestoreCleanupStatus, action: KnowledgeRestoreCleanupAction) {
  return action === "delete"
    ? status.state === "eligible" && status.canDelete
    : (status.state === "cleaning" || status.state === "cleaned") && status.canResume;
}

function validPlan(
  value: unknown,
  status: KnowledgeRestoreCleanupStatus,
  statusSnapshot: string,
  action: KnowledgeRestoreCleanupAction,
  now = Date.now(),
): value is KnowledgeRestoreCleanupPlan {
  if (!record(value) || !exactKeys(value, planKeys) || !status.selected) return false;
  const plan = value as unknown as KnowledgeRestoreCleanupPlan;
  return plan.schemaVersion === 1 && plan.scope === "knowledgeRestoreCleanupPlan" && uuidV4(plan.planId)
    && plan.action === action && actionAllowed(status, action) && validStatus(plan.status, now)
    && snapshot(plan.status) === statusSnapshot && snapshot(status) === statusSnapshot
    && plan.requiresAcknowledgement === true && plan.irreversible === true
    && plan.currentLibraryChanged === false && plan.deletesSnapshot === status.selected.snapshotPresent
    && plan.deletesHistory === true && plan.preservesAuditReceipt === true && plan.reclaimsHistorySlot === true
    && plan.physicalSpaceReclaimedUnknown === true
    && validTime(plan.checkedAtEpochMs) && validTime(plan.expiresAtEpochMs)
    && plan.checkedAtEpochMs <= now && plan.expiresAtEpochMs > now
    && plan.expiresAtEpochMs - plan.checkedAtEpochMs === TTL_MS;
}

function validReceipt(value: unknown, plan: KnowledgeRestoreCleanupPlan, now = Date.now()): value is KnowledgeRestoreCleanupReceipt {
  const selected = plan.status.selected;
  if (!record(value) || !exactKeys(value, receiptKeys) || !selected) return false;
  const receipt = value as unknown as KnowledgeRestoreCleanupReceipt;
  return receipt.schemaVersion === 1 && receipt.scope === "knowledgeRestoreCleanupReceipt"
    && receipt.planId === plan.planId && uuidV4(receipt.cleanupId)
    && (plan.action === "delete" || receipt.cleanupId === plan.status.cleanupId)
    && receipt.transactionId === selected.transactionId && receipt.action === plan.action && receipt.state === "cleaned"
    && validEntry(receipt.selected, now) && snapshot(receipt.selected) === snapshot(selected)
    && receipt.removedFileCount === selected.snapshotFileCount + 2
    && inRange(receipt.removedByteSize, selected.snapshotByteSize, MAX_CLEANUP_BYTES)
    && receipt.currentLibraryChanged === false && receipt.historySlotReleased === true
    && receipt.auditReceiptPersisted === true && receipt.physicalSpaceReclaimedUnknown === true
    && validTime(receipt.completedAtEpochMs) && receipt.completedAtEpochMs >= plan.checkedAtEpochMs
    && receipt.completedAtEpochMs <= now;
}

const recognizablePlanId = (value: unknown) => record(value) && uuidV4(value.planId);

type Context = {
  gateway: KnowledgeRestoreCleanupGateway;
  enabled: boolean;
  disabled: boolean;
  refreshKey: number | undefined;
};
type StatusBinding = { value: KnowledgeRestoreCleanupStatus; snapshot: string; context: Context };
type PlanBinding = { value: KnowledgeRestoreCleanupPlan; snapshot: string; status: StatusBinding; context: Context };

const stateLabel: Record<KnowledgeRestoreCleanupStatus["state"], string> = {
  none: "没有可清理的恢复历史",
  eligible: "最新一条历史可准备永久清理",
  cleaning: "清理意图已持久化，需要恢复",
  cleaned: "清理已完成，需要确认持久化结果",
  blocked: "状态不完整或历史损坏，已阻止清理",
  unavailable: "清理状态不可用",
};
const phaseLabel: Record<KnowledgeRestoreTerminalPhase, string> = {
  committed: "已完成", rolledBack: "已回滚", cancelled: "已取消",
};

export function KnowledgeRestoreCleanupPanel({ gateway, enabled, disabled = false, refreshKey }: KnowledgeRestoreCleanupPanelProps) {
  const [status, setStatus] = useState<KnowledgeRestoreCleanupStatus | null>(null);
  const [plan, setPlan] = useState<KnowledgeRestoreCleanupPlan | null>(null);
  const [receipt, setReceipt] = useState<KnowledgeRestoreCleanupReceipt | null>(null);
  const [acknowledged, setAcknowledged] = useState(false);
  const [busy, setBusy] = useState<"inspecting" | "planning" | "executing" | null>(null);
  const [error, setError] = useState("");
  const context: Context = { gateway, enabled, disabled, refreshKey };
  const contextRef = useRef(context);
  contextRef.current = context;
  const statusRef = useRef<StatusBinding | null>(null);
  const planRef = useRef<PlanBinding | null>(null);
  const receiptRef = useRef<{ value: KnowledgeRestoreCleanupReceipt; context: Context } | null>(null);
  const acknowledgementRef = useRef(false);
  const busyRef = useRef(false);
  const generation = useRef(0);
  const usable = enabled && !disabled;

  const same = (candidate: Context) => {
    const current = contextRef.current;
    return candidate.gateway === current.gateway && candidate.enabled === current.enabled
      && candidate.disabled === current.disabled && candidate.refreshKey === current.refreshKey;
  };
  const discardId = (planId: string, sourceGateway: KnowledgeRestoreCleanupGateway) => {
    void sourceGateway.discardKnowledgeRestoreCleanup(planId).catch(() => undefined);
  };
  const discardPlan = () => {
    const bound = planRef.current;
    planRef.current = null;
    if (bound) discardId(bound.value.planId, bound.context.gateway);
    setPlan(null); acknowledgementRef.current = false; setAcknowledged(false);
  };
  const invalidate = (clearStatus = true) => {
    discardPlan(); generation.current += 1; receiptRef.current = null; setReceipt(null); setError("");
    if (clearStatus) { statusRef.current = null; setStatus(null); }
  };

  const statusBinding = statusRef.current;
  const shownStatus = usable && status && statusBinding?.value === status && same(statusBinding.context)
    && snapshot(status) === statusBinding.snapshot && validStatus(status) ? status : null;
  const planBinding = planRef.current;
  const shownPlan = usable && plan && planBinding?.value === plan && same(planBinding.context)
    && shownStatus && statusBinding && planBinding.status === statusBinding
    && snapshot(plan) === planBinding.snapshot
    && validPlan(plan, shownStatus, statusBinding.snapshot, plan.action) ? plan : null;
  const shownReceipt = usable && receipt && receiptRef.current?.value === receipt && same(receiptRef.current.context) ? receipt : null;

  useEffect(() => {
    const old = planRef.current;
    planRef.current = null;
    if (old) discardId(old.value.planId, old.context.gateway);
    statusRef.current = null; receiptRef.current = null; acknowledgementRef.current = false;
    generation.current += 1; busyRef.current = false;
    setStatus(null); setPlan(null); setReceipt(null); setAcknowledged(false); setBusy(null); setError("");
    return () => {
      const current = planRef.current;
      planRef.current = null;
      if (current) discardId(current.value.planId, current.context.gateway);
      statusRef.current = null; receiptRef.current = null; acknowledgementRef.current = false;
      generation.current += 1; busyRef.current = false;
    };
  }, [gateway, enabled, disabled, refreshKey]);

  useEffect(() => {
    const binding = planRef.current;
    if (!binding || binding.value !== plan) return;
    const timer = window.setTimeout(() => {
      if (planRef.current !== binding) return;
      discardPlan(); statusRef.current = null; setStatus(null); generation.current += 1;
      setError("永久清理计划已过期，请重新检查并准备。");
    }, Math.max(0, binding.value.expiresAtEpochMs - Date.now()));
    return () => window.clearTimeout(timer);
  }, [plan?.planId, plan?.expiresAtEpochMs]);

  async function inspect() {
    const requestContext = { ...contextRef.current };
    if (!same(context) || !requestContext.enabled || requestContext.disabled || busyRef.current) return;
    invalidate();
    const request = ++generation.current; busyRef.current = true; setBusy("inspecting");
    try {
      const next: unknown = await requestContext.gateway.inspectKnowledgeRestoreCleanup();
      if (request !== generation.current || !same(requestContext)) return;
      if (!validStatus(next)) throw new Error("invalid cleanup status");
      const accepted = copy(next);
      if (!validStatus(accepted)) throw new Error("invalid copied cleanup status");
      const binding: StatusBinding = { value: accepted, snapshot: snapshot(accepted), context: requestContext };
      statusRef.current = binding; setStatus(accepted);
    } catch {
      if (request === generation.current && same(requestContext)) {
        setError("无法核验恢复历史清理状态；读取失败不表示可以删除。请重新手动检查，系统不会自动重试。");
      }
    } finally {
      if (request === generation.current) { busyRef.current = false; setBusy(null); }
    }
  }

  async function prepare(action: KnowledgeRestoreCleanupAction) {
    const currentStatus = shownStatus;
    const currentBinding = statusRef.current;
    const requestContext = { ...contextRef.current };
    if (!currentStatus || !currentBinding || !currentStatus.selected || !same(context)
      || !same(requestContext) || !requestContext.enabled || requestContext.disabled || busyRef.current
      || snapshot(currentStatus) !== currentBinding.snapshot || !actionAllowed(currentStatus, action)) return;
    discardPlan(); receiptRef.current = null; setReceipt(null); setError("");
    const request = ++generation.current; busyRef.current = true; setBusy("planning");
    try {
      const next: unknown = await requestContext.gateway.planKnowledgeRestoreCleanup(currentStatus.selected.transactionId, action);
      if (request !== generation.current || !same(requestContext) || statusRef.current !== currentBinding) {
        if (recognizablePlanId(next)) discardId((next as { planId: string }).planId, requestContext.gateway);
        return;
      }
      if (!validPlan(next, currentStatus, currentBinding.snapshot, action)) {
        if (recognizablePlanId(next)) discardId((next as { planId: string }).planId, requestContext.gateway);
        throw new Error("invalid cleanup plan");
      }
      const accepted = copy(next);
      if (!validPlan(accepted, currentStatus, currentBinding.snapshot, action)) throw new Error("invalid copied cleanup plan");
      const binding: PlanBinding = { value: accepted, snapshot: snapshot(accepted), status: currentBinding, context: requestContext };
      planRef.current = binding; setPlan(accepted);
    } catch {
      if (request === generation.current && same(requestContext)) {
        setError("永久清理计划无效；请重新检查状态。系统不会自动删除、恢复或重试。");
      }
    } finally {
      if (request === generation.current) { busyRef.current = false; setBusy(null); }
    }
  }

  async function execute() {
    const binding = planRef.current;
    const currentStatusBinding = statusRef.current;
    const requestContext = { ...contextRef.current };
    if (!binding || !currentStatusBinding || !same(context) || !same(requestContext) || !requestContext.enabled
      || requestContext.disabled || busyRef.current || !acknowledged || !acknowledgementRef.current
      || !same(binding.context) || binding.status !== currentStatusBinding || snapshot(binding.value) !== binding.snapshot) return;
    const now = Date.now();
    if (now < binding.value.checkedAtEpochMs || now >= binding.value.expiresAtEpochMs
      || !validPlan(binding.value, currentStatusBinding.value, currentStatusBinding.snapshot, binding.value.action, now)) {
      discardPlan(); statusRef.current = null; setStatus(null); generation.current += 1;
      setError("永久清理计划已过期或系统时间已变化，请重新检查并准备。"); return;
    }

    // Consume the one-use UI capability before crossing the gateway boundary.
    planRef.current = null; statusRef.current = null; receiptRef.current = null;
    setPlan(null); setStatus(null); setReceipt(null); acknowledgementRef.current = false; setAcknowledged(false); setError("");
    const request = ++generation.current; busyRef.current = true; setBusy("executing");
    try {
      const next: unknown = await requestContext.gateway.executeKnowledgeRestoreCleanup(binding.value.planId, true);
      if (request !== generation.current || !same(requestContext)) return;
      if (!validReceipt(next, binding.value)) throw new Error("invalid cleanup receipt");
      const accepted = copy(next);
      if (!validReceipt(accepted, binding.value)) throw new Error("invalid copied cleanup receipt");
      receiptRef.current = { value: accepted, context: requestContext }; setReceipt(accepted);
    } catch {
      if (request === generation.current && same(requestContext)) {
        setError("永久清理可能已经发生，但完成状态未知；计划已消耗。请重新手动检查，系统不会自动重试。");
      }
    } finally {
      if (request === generation.current) { busyRef.current = false; setBusy(null); }
    }
  }

  function changeAcknowledgement(value: boolean) {
    if (!shownPlan || busyRef.current || !usable || !same(context)) return;
    acknowledgementRef.current = value; setAcknowledged(value);
  }

  function abandonPlan() {
    if (!shownPlan || busyRef.current || !usable || !same(context)) return;
    discardPlan(); generation.current += 1; setError("");
  }

  if (!enabled) return null;
  return <section className="operation-plan" aria-label="知识库恢复历史永久清理" aria-busy={busy !== null}>
    <h4>知识库恢复历史永久清理</h4>
    <p className="publish-muted">手动检查后，只能选择最新一条恢复历史，准备一次性永久清理或恢复已中断的清理。</p>
    <p className="publish-warning">清理会永久删除所选最新历史的完整快照、原始事务日志和历史记录，仅保留精简审计回执；当前资料库保持不变。显示的是逻辑字节数，不保证磁盘物理空间已经回收。</p>
    <button type="button" onClick={() => void inspect()} disabled={!usable || busy !== null}>检查永久清理状态</button>
    {busy && <p role="status">{busy === "inspecting" ? "正在只读检查清理状态…" : busy === "planning" ? "正在准备一次性永久清理计划…" : "正在执行一次性永久清理…"}</p>}
    {error && <p role="alert" className="publish-warning">{error}</p>}

    {shownStatus && <div className="operation-plan">
      <p><strong>只读清理状态</strong></p>
      <p>状态：{stateLabel[shownStatus.state]}</p>
      {shownStatus.historyCount !== null && shownStatus.receiptCount !== null && <p>恢复历史：{shownStatus.historyCount}/{shownStatus.historyLimit}；审计回执：{shownStatus.receiptCount}/{shownStatus.receiptLimit}</p>}
      {shownStatus.selected && <p>所选最新历史：{shownStatus.selected.transactionId}；终态：{phaseLabel[shownStatus.selected.phase]}；归档时间：{shownStatus.selected.archivedAtEpochMs}</p>}
      {shownStatus.currentManifestSha256 && <p>当前资料库清单 SHA-256：{shownStatus.currentManifestSha256}</p>}
      {shownStatus.remainingFileCount !== null && shownStatus.remainingByteSize !== null && <p>待清理逻辑范围：文件 {shownStatus.remainingFileCount}；字节 {shownStatus.remainingByteSize}</p>}
      <p>资料库访问：{shownStatus.libraryAccessBlocked ? "已阻止" : "可用"}；历史槽：{shownStatus.historySlotReleased ? "已释放" : "未释放"}</p>
      {shownStatus.canDelete && <button type="button" onClick={() => void prepare("delete")} disabled={busy !== null}>准备永久删除计划</button>}
      {shownStatus.canResume && <button type="button" onClick={() => void prepare("resume")} disabled={busy !== null}>准备恢复清理计划</button>}
      {!shownStatus.canDelete && !shownStatus.canResume && <p className="publish-muted">当前状态没有可准备的永久清理操作。</p>}
    </div>}

    {shownPlan && <div className="operation-plan">
      <p><strong>{shownPlan.action === "delete" ? "永久删除计划" : "恢复清理计划"}（一次性，5 分钟内有效）</strong></p>
      <p>所选最新历史：{shownPlan.status.selected?.transactionId}；操作：{shownPlan.action === "delete" ? "开始永久清理" : "恢复已中断清理"}</p>
      <p className="publish-warning">确认后会永久删除所选最新历史的{shownPlan.deletesSnapshot ? "完整快照、" : ""}原始事务日志和历史记录，仅保留精简审计回执。当前资料库不会改变；逻辑字节数不保证磁盘物理空间已经回收。</p>
      <label><input type="checkbox" checked={acknowledged} onChange={(event) => changeAcknowledgement(event.target.checked)} disabled={busy !== null} />我确认永久删除所选最新历史的完整快照（如有）、原始事务日志和历史记录，仅保留精简审计回执；当前资料库保持不变，并理解逻辑字节数不保证磁盘物理空间已经回收。</label>
      <button type="button" onClick={() => void execute()} disabled={!acknowledged || busy !== null}>确认并执行永久清理</button>
      <button type="button" onClick={abandonPlan} disabled={busy !== null}>放弃永久清理计划</button>
    </div>}

    {shownReceipt && <div className="operation-plan">
      <p role="status">所选最新恢复历史已永久清理，历史槽已释放，精简审计回执已持久化。</p>
      <p>事务 ID：{shownReceipt.transactionId}；清理 ID：{shownReceipt.cleanupId}；移除逻辑文件 {shownReceipt.removedFileCount}；逻辑字节 {shownReceipt.removedByteSize}。</p>
      <p>当前资料库未改变；逻辑字节数不保证磁盘物理空间已经回收。</p>
    </div>}
  </section>;
}
