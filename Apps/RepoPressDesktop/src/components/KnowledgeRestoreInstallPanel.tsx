import { useEffect, useRef, useState } from "react";
import type {
  KnowledgeRestoreDiagnosis,
  KnowledgeRestoreInstallGateway,
  KnowledgeRestoreInstallPlan,
  KnowledgeRestoreReceipt,
  KnowledgeRestoreRecoveryAction,
  KnowledgeRestoreRecoveryPlan,
} from "../contracts/knowledgeRestoreInstall";
import type { KnowledgeRestoreStrategy } from "../contracts/knowledgeRestoreQualification";
import { validKnowledgeMergeProjectionPlan } from "./KnowledgeMergeProjectionPanel";

export interface KnowledgeRestoreInstallPanelProps {
  gateway: KnowledgeRestoreInstallGateway;
  enabled: boolean;
  disabled?: boolean;
  refreshKey?: number;
}

const strategies: KnowledgeRestoreStrategy[] = ["requireNoIdentityConflicts", "keepCurrentIdentities"];
const installPlanKeys = ["schemaVersion", "scope", "planId", "projection", "requiresAcknowledgement", "writesCurrentLibrary", "preservesRollbackSnapshot", "importedPermissionsDisabled", "currentOnlyPreserved", "completedOperationsExcluded", "transactionLimit", "checkedAtEpochMs", "expiresAtEpochMs"] as const;
const diagnosisKeys = ["schemaVersion", "scope", "state", "transactionId", "phase", "previousManifestSha256", "projectedManifestSha256", "canFinalize", "canRollback", "canCancel", "libraryAccessBlocked", "snapshotRetained", "filesystemWrites"] as const;
const recoveryPlanKeys = ["schemaVersion", "scope", "planId", "transactionId", "action", "diagnosis", "requiresAcknowledgement", "preservesSnapshot", "checkedAtEpochMs", "expiresAtEpochMs"] as const;
const receiptKeys = ["schemaVersion", "scope", "planId", "transactionId", "state", "action", "previousManifestSha256", "projectedManifestSha256", "importedPermissionsDisabled", "snapshotRetained", "journalPersisted", "libraryAccessBlocked", "completedAtEpochMs"] as const;
const diagnosisStates: KnowledgeRestoreDiagnosis["state"][] = ["none", "preparing", "prepared", "installed", "committed", "rolledBack", "cancelled", "changed", "invalid", "unavailable"];
const phases: Exclude<KnowledgeRestoreDiagnosis["phase"], null>[] = ["preparing", "intent", "committed", "rolledBack", "cancelled"];
const actions: KnowledgeRestoreRecoveryAction[] = ["finalize", "rollback", "cancel"];

const exact = (value: unknown, keys: readonly string[]) => !!value && typeof value === "object"
  && !Array.isArray(value) && Object.keys(value).length === keys.length
  && keys.every(key => Object.prototype.hasOwnProperty.call(value, key));
const safeTime = (value: unknown): value is number => typeof value === "number" && Number.isSafeInteger(value)
  && value > 0 && value <= 8.64e15;
const uuid = (value: unknown): value is string => typeof value === "string"
  && /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(value);
const sha256 = (value: unknown): value is string => typeof value === "string" && /^[0-9a-f]{64}$/.test(value);
const absolutePath = (value: unknown): value is string => typeof value === "string" && value.startsWith("/")
  && new TextEncoder().encode(value).byteLength <= 4096 && value !== "/" && !value.endsWith("/")
  && !value.includes("\0") && !value.includes("//") && value.slice(1).split("/").every(part => part !== "." && part !== "..");
const candidatePath = (value: unknown): value is string => absolutePath(value)
  && /^repopress-knowledge-stage-[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(value.slice(value.lastIndexOf("/") + 1));
const copy = <T,>(value: T): T => JSON.parse(JSON.stringify(value)) as T;
function canonical(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(canonical);
  if (value && typeof value === "object") return Object.fromEntries(
    Object.keys(value).sort().map(key => [key, canonical((value as Record<string, unknown>)[key])]),
  );
  return value;
}
const snapshot = (value: unknown) => JSON.stringify(canonical(value));

function validInstallPlan(
  value: unknown,
  path: string,
  strategy: KnowledgeRestoreStrategy,
  now = Date.now(),
): value is KnowledgeRestoreInstallPlan {
  if (!exact(value, installPlanKeys)) return false;
  const plan = value as KnowledgeRestoreInstallPlan;
  const projection = plan.projection;
  return plan.schemaVersion === 1
    && plan.scope === "knowledgeRestoreInstall"
    && uuid(plan.planId)
    && validKnowledgeMergeProjectionPlan(projection, path, strategy, now)
    && projection.projection.state === "validated"
    && projection.projection.reason === "none"
    && projection.projectedManifestValidated === true
    && projection.source.qualification.state === "evidenceReady"
    && plan.requiresAcknowledgement === true
    && plan.writesCurrentLibrary === true
    && plan.preservesRollbackSnapshot === true
    && plan.importedPermissionsDisabled === true
    && plan.currentOnlyPreserved === true
    && plan.completedOperationsExcluded === true
    && plan.transactionLimit === 1
    && safeTime(plan.checkedAtEpochMs)
    && safeTime(plan.expiresAtEpochMs)
    && plan.checkedAtEpochMs === projection.checkedAtEpochMs
    && plan.expiresAtEpochMs === projection.expiresAtEpochMs
    && plan.checkedAtEpochMs <= now
    && plan.expiresAtEpochMs > now
    && plan.expiresAtEpochMs - plan.checkedAtEpochMs === 300000;
}

function validDiagnosis(value: unknown): value is KnowledgeRestoreDiagnosis {
  if (!exact(value, diagnosisKeys)) return false;
  const diagnosis = value as KnowledgeRestoreDiagnosis;
  if (diagnosis.schemaVersion !== 1 || diagnosis.scope !== "knowledgeRestoreDiagnosis"
    || !diagnosisStates.includes(diagnosis.state)
    || !(diagnosis.phase === null || phases.includes(diagnosis.phase))
    || typeof diagnosis.canFinalize !== "boolean" || typeof diagnosis.canRollback !== "boolean"
    || typeof diagnosis.canCancel !== "boolean" || typeof diagnosis.libraryAccessBlocked !== "boolean"
    || typeof diagnosis.snapshotRetained !== "boolean" || diagnosis.filesystemWrites !== false) return false;

  if (["none", "invalid", "unavailable"].includes(diagnosis.state)) {
    const expectedBlocked = diagnosis.state !== "none";
    return diagnosis.transactionId === null && diagnosis.phase === null
      && diagnosis.previousManifestSha256 === null && diagnosis.projectedManifestSha256 === null
      && !diagnosis.canFinalize && !diagnosis.canRollback && !diagnosis.canCancel
      && !diagnosis.snapshotRetained && diagnosis.libraryAccessBlocked === expectedBlocked;
  }
  if (!uuid(diagnosis.transactionId) || !sha256(diagnosis.previousManifestSha256)
    || !sha256(diagnosis.projectedManifestSha256)) return false;

  switch (diagnosis.state) {
    case "preparing":
      return diagnosis.phase === "preparing" && !diagnosis.snapshotRetained && diagnosis.libraryAccessBlocked
        && !diagnosis.canFinalize && !diagnosis.canRollback && diagnosis.canCancel;
    case "prepared":
      return diagnosis.phase === "intent" && diagnosis.snapshotRetained && diagnosis.libraryAccessBlocked
        && !diagnosis.canFinalize && !diagnosis.canRollback && diagnosis.canCancel;
    case "installed":
      return diagnosis.phase === "intent" && diagnosis.snapshotRetained && diagnosis.libraryAccessBlocked
        && diagnosis.canFinalize && diagnosis.canRollback && !diagnosis.canCancel;
    case "committed":
      return diagnosis.phase === "committed" && diagnosis.snapshotRetained && !diagnosis.libraryAccessBlocked
        && !diagnosis.canFinalize && diagnosis.canRollback && !diagnosis.canCancel;
    case "rolledBack":
      return diagnosis.phase === "rolledBack" && diagnosis.snapshotRetained && !diagnosis.libraryAccessBlocked
        && !diagnosis.canFinalize && !diagnosis.canRollback && !diagnosis.canCancel;
    case "cancelled":
      return diagnosis.phase === "cancelled" && !diagnosis.libraryAccessBlocked
        && !diagnosis.canFinalize && !diagnosis.canRollback && !diagnosis.canCancel;
    case "changed":
      return diagnosis.phase !== null
        && (!["preparing", "intent"].includes(diagnosis.phase) || diagnosis.libraryAccessBlocked)
        && !diagnosis.canFinalize && !diagnosis.canRollback && !diagnosis.canCancel;
    default:
      return false;
  }
}

function actionAllowed(diagnosis: KnowledgeRestoreDiagnosis, action: KnowledgeRestoreRecoveryAction) {
  return action === "finalize" ? diagnosis.canFinalize : action === "rollback" ? diagnosis.canRollback : diagnosis.canCancel;
}

function validRecoveryPlan(
  value: unknown,
  diagnosis: KnowledgeRestoreDiagnosis,
  diagnosisSnapshot: string,
  action: KnowledgeRestoreRecoveryAction,
  now = Date.now(),
): value is KnowledgeRestoreRecoveryPlan {
  if (!exact(value, recoveryPlanKeys)) return false;
  const plan = value as KnowledgeRestoreRecoveryPlan;
  return plan.schemaVersion === 1 && plan.scope === "knowledgeRestoreRecovery" && uuid(plan.planId)
    && uuid(plan.transactionId) && plan.transactionId === diagnosis.transactionId
    && actions.includes(plan.action) && plan.action === action && actionAllowed(diagnosis, action)
    && validDiagnosis(plan.diagnosis) && snapshot(plan.diagnosis) === diagnosisSnapshot
    && plan.requiresAcknowledgement === true && plan.preservesSnapshot === true
    && safeTime(plan.checkedAtEpochMs) && safeTime(plan.expiresAtEpochMs)
    && plan.checkedAtEpochMs <= now && plan.expiresAtEpochMs > now
    && plan.expiresAtEpochMs - plan.checkedAtEpochMs === 300000;
}

function validReceiptForInstall(value: unknown, plan: KnowledgeRestoreInstallPlan, now = Date.now()): value is KnowledgeRestoreReceipt {
  if (!exact(value, receiptKeys)) return false;
  const receipt = value as KnowledgeRestoreReceipt;
  return receipt.schemaVersion === 1 && receipt.scope === "knowledgeRestoreReceipt"
    && uuid(receipt.planId) && receipt.planId === plan.planId && uuid(receipt.transactionId)
    && receipt.state === "committed" && receipt.action === "install"
    && receipt.previousManifestSha256 === plan.projection.source.candidate.currentLibrary.manifestSha256
    && receipt.projectedManifestSha256 === plan.projection.projection.manifestSha256
    && validReceiptFlagsAndTime(receipt, true, plan.checkedAtEpochMs, plan.expiresAtEpochMs, now);
}

function validReceiptForRecovery(value: unknown, plan: KnowledgeRestoreRecoveryPlan, now = Date.now()): value is KnowledgeRestoreReceipt {
  if (!exact(value, receiptKeys)) return false;
  const receipt = value as KnowledgeRestoreReceipt;
  const expectedState = plan.action === "finalize" ? "committed" : plan.action === "rollback" ? "rolledBack" : "cancelled";
  return receipt.schemaVersion === 1 && receipt.scope === "knowledgeRestoreReceipt"
    && uuid(receipt.planId) && receipt.planId === plan.planId
    && uuid(receipt.transactionId) && receipt.transactionId === plan.transactionId
    && receipt.action === plan.action && receipt.state === expectedState
    && receipt.previousManifestSha256 === plan.diagnosis.previousManifestSha256
    && receipt.projectedManifestSha256 === plan.diagnosis.projectedManifestSha256
    && validReceiptFlagsAndTime(receipt, plan.action === "cancel" ? plan.diagnosis.snapshotRetained : true,
      plan.checkedAtEpochMs, plan.expiresAtEpochMs, now);
}

function validReceiptFlagsAndTime(receipt: KnowledgeRestoreReceipt, snapshotRetained: boolean, checkedAt: number, expiresAt: number, now: number) {
  return receipt.importedPermissionsDisabled === true && receipt.snapshotRetained === snapshotRetained
    && receipt.journalPersisted === true && receipt.libraryAccessBlocked === false
    && safeTime(receipt.completedAtEpochMs) && receipt.completedAtEpochMs >= checkedAt
    && receipt.completedAtEpochMs <= now && receipt.completedAtEpochMs < expiresAt;
}

const recognizablePlanId = (value: unknown) => !!value && typeof value === "object"
  && uuid((value as { planId?: unknown }).planId);
const strategyLabel = (value: KnowledgeRestoreStrategy) => value === "requireNoIdentityConflicts" ? "要求无身份冲突" : "保留当前数据";
const actionLabel: Record<KnowledgeRestoreRecoveryAction, string> = { finalize: "完成事务", rollback: "回滚事务", cancel: "取消准备" };
const diagnosisLabel: Record<KnowledgeRestoreDiagnosis["state"], string> = {
  none: "没有恢复事务", preparing: "正在准备恢复事务", prepared: "恢复事务已准备", installed: "资料库已安装，等待完成或回滚",
  committed: "恢复事务已完成", rolledBack: "恢复事务已回滚", cancelled: "恢复事务已取消", changed: "资料库状态已变化",
  invalid: "恢复记录无效", unavailable: "恢复状态不可用",
};

type Context = {
  gateway: KnowledgeRestoreInstallGateway;
  enabled: boolean;
  disabled: boolean;
  refreshKey: number | undefined;
  path: string | null;
  strategy: KnowledgeRestoreStrategy;
};
type BoundPlan =
  | { kind: "install"; plan: KnowledgeRestoreInstallPlan; snapshot: string; context: Context }
  | { kind: "recovery"; plan: KnowledgeRestoreRecoveryPlan; snapshot: string; context: Context };

export function KnowledgeRestoreInstallPanel({ gateway, enabled, disabled = false, refreshKey }: KnowledgeRestoreInstallPanelProps) {
  const [pathValue, setPathValue] = useState<string | null>(null);
  const [strategy, setStrategy] = useState<KnowledgeRestoreStrategy>("requireNoIdentityConflicts");
  const [installPlan, setInstallPlan] = useState<KnowledgeRestoreInstallPlan | null>(null);
  const [recoveryPlan, setRecoveryPlan] = useState<KnowledgeRestoreRecoveryPlan | null>(null);
  const [diagnosis, setDiagnosis] = useState<KnowledgeRestoreDiagnosis | null>(null);
  const [receipt, setReceipt] = useState<KnowledgeRestoreReceipt | null>(null);
  const [acknowledged, setAcknowledged] = useState(false);
  const [busy, setBusy] = useState<"selecting" | "planningInstall" | "inspecting" | "planningRecovery" | "executing" | null>(null);
  const [error, setError] = useState("");
  const renderContext: Context = { gateway, enabled, disabled, refreshKey, path: pathValue, strategy };
  const contextRef = useRef<Context>(renderContext);
  contextRef.current = renderContext;
  const boundPlanRef = useRef<BoundPlan | null>(null);
  const diagnosisRef = useRef<{ value: KnowledgeRestoreDiagnosis; snapshot: string; context: Context } | null>(null);
  const receiptRef = useRef<{ value: KnowledgeRestoreReceipt; context: Context } | null>(null);
  const acknowledgementRef = useRef(false);
  const generation = useRef(0);
  const busyRef = useRef(false);
  const usable = enabled && !disabled;

  const same = (context: Context) => {
    const current = contextRef.current;
    return context.gateway === current.gateway && context.enabled === current.enabled
      && context.disabled === current.disabled && context.refreshKey === current.refreshKey
      && context.path === current.path && context.strategy === current.strategy;
  };
  const discardId = (planId: string, sourceGateway: KnowledgeRestoreInstallGateway) => {
    void sourceGateway.discardKnowledgeRestoreInstall(planId).catch(() => undefined);
  };
  const discardBoundPlan = () => {
    const bound = boundPlanRef.current;
    boundPlanRef.current = null;
    if (bound) discardId(bound.plan.planId, bound.context.gateway);
    setInstallPlan(null); setRecoveryPlan(null);
    acknowledgementRef.current = false; setAcknowledged(false);
  };
  const invalidate = (clearDiagnosis = true) => {
    discardBoundPlan(); generation.current += 1; receiptRef.current = null; setReceipt(null); setError("");
    if (clearDiagnosis) { diagnosisRef.current = null; setDiagnosis(null); }
  };
  const diagnosisCurrent = diagnosisRef.current;
  const shownDiagnosis = usable && diagnosis && diagnosisCurrent?.value === diagnosis
    && same(diagnosisCurrent.context) && validDiagnosis(diagnosis)
    && snapshot(diagnosis) === diagnosisCurrent.snapshot ? diagnosis : null;
  const bound = boundPlanRef.current;
  const shownInstallPlan = usable && installPlan && bound?.kind === "install" && bound.plan === installPlan
    && same(bound.context) && snapshot(installPlan) === bound.snapshot
    && validInstallPlan(installPlan, contextRef.current.path ?? "", contextRef.current.strategy) ? installPlan : null;
  const shownRecoveryPlan = usable && recoveryPlan && bound?.kind === "recovery" && bound.plan === recoveryPlan
    && same(bound.context) && snapshot(recoveryPlan) === bound.snapshot
    && shownDiagnosis && diagnosisCurrent
    && validRecoveryPlan(recoveryPlan, shownDiagnosis, diagnosisCurrent.snapshot, recoveryPlan.action) ? recoveryPlan : null;
  const shownReceipt = usable && receipt && receiptRef.current?.value === receipt
    && same(receiptRef.current.context) ? receipt : null;

  useEffect(() => {
    const old = boundPlanRef.current;
    boundPlanRef.current = null;
    if (old) discardId(old.plan.planId, old.context.gateway);
    diagnosisRef.current = null; receiptRef.current = null; acknowledgementRef.current = false;
    generation.current += 1; busyRef.current = false;
    contextRef.current = { gateway, enabled, disabled, refreshKey, path: null, strategy: "requireNoIdentityConflicts" };
    setPathValue(null); setStrategy("requireNoIdentityConflicts"); setInstallPlan(null); setRecoveryPlan(null);
    setDiagnosis(null); setReceipt(null); setAcknowledged(false); setBusy(null); setError("");
    return () => {
      const current = boundPlanRef.current;
      boundPlanRef.current = null;
      if (current) discardId(current.plan.planId, current.context.gateway);
      diagnosisRef.current = null; receiptRef.current = null; acknowledgementRef.current = false;
      generation.current += 1; busyRef.current = false;
    };
  }, [gateway, enabled, disabled, refreshKey]);

  useEffect(() => {
    const current = boundPlanRef.current;
    const plan = current?.plan;
    if (!plan) return;
    const timer = window.setTimeout(() => {
      if (boundPlanRef.current === current) {
        discardBoundPlan(); generation.current += 1;
        setError("计划已过期，请重新准备。");
      }
    }, Math.max(0, plan.expiresAtEpochMs - Date.now()));
    return () => window.clearTimeout(timer);
  }, [installPlan?.planId, installPlan?.expiresAtEpochMs, recoveryPlan?.planId, recoveryPlan?.expiresAtEpochMs]);

  async function selectCandidate() {
    const before = { ...contextRef.current };
    if (!same(renderContext) || !before.enabled || before.disabled || busyRef.current) return;
    invalidate();
    contextRef.current.path = null; setPathValue(null);
    const context = { ...contextRef.current };
    const request = ++generation.current; busyRef.current = true; setBusy("selecting");
    try {
      const next = await before.gateway.selectKnowledgeCandidateDirectory();
      if (request !== generation.current || !same(context)) return;
      if (next !== null && !candidatePath(next)) throw new Error("invalid path");
      contextRef.current.path = next; setPathValue(next);
    } catch {
      if (request === generation.current && same(context)) setError("无法选择候选目录。");
    } finally {
      if (request === generation.current) { busyRef.current = false; setBusy(null); }
    }
  }

  async function prepareInstall() {
    const context = { ...contextRef.current };
    if (!same(renderContext) || !candidatePath(context.path) || !context.enabled || context.disabled || busyRef.current) return;
    invalidate();
    const request = ++generation.current; busyRef.current = true; setBusy("planningInstall");
    try {
      const next: unknown = await context.gateway.planKnowledgeRestoreInstall(context.path, context.strategy);
      if (request !== generation.current || !same(context)) {
        if (recognizablePlanId(next)) discardId((next as { planId: string }).planId, context.gateway);
        return;
      }
      if (!validInstallPlan(next, context.path, context.strategy)) {
        if (recognizablePlanId(next)) discardId((next as { planId: string }).planId, context.gateway);
        throw new Error("invalid install plan");
      }
      const accepted = copy(next);
      if (!validInstallPlan(accepted, context.path, context.strategy)) throw new Error("invalid copied install plan");
      const planBinding: BoundPlan = { kind: "install", plan: accepted, snapshot: snapshot(accepted), context };
      boundPlanRef.current = planBinding; setInstallPlan(accepted);
    } catch {
      if (request === generation.current && same(context)) setError("安装计划无效或当前不允许开始新的恢复事务。");
    } finally {
      if (request === generation.current) { busyRef.current = false; setBusy(null); }
    }
  }

  async function inspectRecovery() {
    const context = { ...contextRef.current };
    if (!same(renderContext) || !context.enabled || context.disabled || busyRef.current) return;
    invalidate();
    const request = ++generation.current; busyRef.current = true; setBusy("inspecting");
    try {
      const next: unknown = await context.gateway.inspectKnowledgeRestore();
      if (request !== generation.current || !same(context)) return;
      if (!validDiagnosis(next)) throw new Error("invalid diagnosis");
      const accepted = copy(next);
      if (!validDiagnosis(accepted)) throw new Error("invalid copied diagnosis");
      diagnosisRef.current = { value: accepted, snapshot: snapshot(accepted), context };
      setDiagnosis(accepted);
    } catch {
      if (request === generation.current && same(context)) setError("无法读取恢复状态；读取失败不表示没有未完成事务。");
    } finally {
      if (request === generation.current) { busyRef.current = false; setBusy(null); }
    }
  }

  async function prepareRecovery(action: KnowledgeRestoreRecoveryAction) {
    const currentDiagnosis = shownDiagnosis;
    const diagnosisBinding = diagnosisRef.current;
    const context = { ...contextRef.current };
    if (!currentDiagnosis || !diagnosisBinding || !same(renderContext) || !context.enabled || context.disabled
      || busyRef.current || !actionAllowed(currentDiagnosis, action)
      || snapshot(currentDiagnosis) !== diagnosisBinding.snapshot || currentDiagnosis.transactionId === null) return;
    discardBoundPlan(); receiptRef.current = null; setReceipt(null); setError("");
    const request = ++generation.current; busyRef.current = true; setBusy("planningRecovery");
    try {
      const next: unknown = await context.gateway.planKnowledgeRestoreRecovery(currentDiagnosis.transactionId, action);
      if (request !== generation.current || !same(context) || diagnosisRef.current !== diagnosisBinding) {
        if (recognizablePlanId(next)) discardId((next as { planId: string }).planId, context.gateway);
        return;
      }
      if (!validRecoveryPlan(next, currentDiagnosis, diagnosisBinding.snapshot, action)) {
        if (recognizablePlanId(next)) discardId((next as { planId: string }).planId, context.gateway);
        throw new Error("invalid recovery plan");
      }
      const accepted = copy(next);
      if (!validRecoveryPlan(accepted, currentDiagnosis, diagnosisBinding.snapshot, action)) throw new Error("invalid copied recovery plan");
      const planBinding: BoundPlan = { kind: "recovery", plan: accepted, snapshot: snapshot(accepted), context };
      boundPlanRef.current = planBinding; setRecoveryPlan(accepted);
    } catch {
      if (request === generation.current && same(context)) setError("恢复操作计划无效，请重新检查恢复状态。");
    } finally {
      if (request === generation.current) { busyRef.current = false; setBusy(null); }
    }
  }

  async function execute() {
    const currentBinding = boundPlanRef.current;
    const context = { ...contextRef.current };
    if (!currentBinding || !same(renderContext) || !context.enabled || context.disabled || busyRef.current
      || !acknowledged || !acknowledgementRef.current || !same(currentBinding.context)
      || snapshot(currentBinding.plan) !== currentBinding.snapshot) return;
    const now = Date.now();
    if (now >= currentBinding.plan.expiresAtEpochMs) {
      discardBoundPlan(); generation.current += 1; setError("计划已过期，请重新准备。"); return;
    }
    if (currentBinding.kind === "install") {
      if (!validInstallPlan(currentBinding.plan, context.path ?? "", context.strategy, now)) return;
    } else {
      const diagnosisBinding = diagnosisRef.current;
      if (!diagnosisBinding || diagnosisBinding.value !== shownDiagnosis
        || !validRecoveryPlan(currentBinding.plan, diagnosisBinding.value, diagnosisBinding.snapshot, currentBinding.plan.action, now)) return;
    }

    boundPlanRef.current = null; setInstallPlan(null); setRecoveryPlan(null);
    acknowledgementRef.current = false; setAcknowledged(false); receiptRef.current = null; setReceipt(null); setError("");
    const request = ++generation.current; busyRef.current = true; setBusy("executing");
    try {
      const next: unknown = currentBinding.kind === "install"
        ? await context.gateway.executeKnowledgeRestoreInstall(currentBinding.plan.planId, true)
        : await context.gateway.executeKnowledgeRestoreRecovery(currentBinding.plan.planId, true);
      if (request !== generation.current || !same(context)) return;
      const valid = currentBinding.kind === "install"
        ? validReceiptForInstall(next, currentBinding.plan)
        : validReceiptForRecovery(next, currentBinding.plan);
      if (!valid) throw new Error("invalid receipt");
      const accepted = copy(next as KnowledgeRestoreReceipt);
      const copiedValid = currentBinding.kind === "install"
        ? validReceiptForInstall(accepted, currentBinding.plan)
        : validReceiptForRecovery(accepted, currentBinding.plan);
      if (!copiedValid) throw new Error("invalid copied receipt");
      receiptRef.current = { value: accepted, context }; setReceipt(accepted);
      diagnosisRef.current = null; setDiagnosis(null);
    } catch {
      if (request === generation.current && same(context)) setError("可能已写入文件，未确认完成；请检查恢复状态，系统不会自动重试。");
    } finally {
      if (request === generation.current) { busyRef.current = false; setBusy(null); }
    }
  }

  function changeStrategy(value: KnowledgeRestoreStrategy) {
    if (!strategies.includes(value) || value === contextRef.current.strategy || !usable || busyRef.current || !same(renderContext)) return;
    invalidate(); contextRef.current.strategy = value; setStrategy(value);
  }
  function changeAcknowledgement(value: boolean) {
    if (!boundPlanRef.current || busyRef.current || !usable || !same(renderContext)) return;
    acknowledgementRef.current = value; setAcknowledged(value);
  }
  function abandonPlan() {
    if (!boundPlanRef.current || busyRef.current || !usable || !same(renderContext)) return;
    discardBoundPlan(); generation.current += 1; setError("");
  }

  const projection = shownInstallPlan?.projection.projection;
  return <section className="operation-plan" aria-label="知识库恢复安装与恢复" aria-busy={busy !== null}>
    <h4>知识库恢复安装与恢复</h4>
    <p className="publish-muted">安装会写入当前资料库；当前独有资料会保留，导入资料的 AI 与语义索引授权保持关闭，旧快照会保留。</p>
    <p className="publish-warning">安装要求当前资料库的已保存文件树完整闭合；发现未知或未引用文件时会拒绝安装。外部附件与来源真实性不在本次核验范围内。</p>
    <p className="publish-warning">唯一持久事务槽即使在完成、回滚或取消后仍被占用。保留的旧库或暂存快照可能包含私密明文；本页不清理、不释放容量，也不会隐式删除。</p>
    <button type="button" onClick={() => void selectCandidate()} disabled={!usable || busy !== null}>选择候选目录</button>
    {pathValue && <p>候选路径：{pathValue}</p>}
    <label>恢复策略：<select value={strategy} onChange={event => changeStrategy(event.target.value as KnowledgeRestoreStrategy)} disabled={!usable || busy !== null}>
      {strategies.map(value => <option key={value} value={value}>{strategyLabel(value)}</option>)}
    </select></label>
    {pathValue && <button type="button" onClick={() => void prepareInstall()} disabled={!usable || busy !== null}>准备安装计划</button>}
    <button type="button" onClick={() => void inspectRecovery()} disabled={!usable || busy !== null}>检查恢复状态</button>
    {busy && <p role="status">{busy === "selecting" ? "正在选择目录…" : busy === "planningInstall" ? "正在准备安装计划…"
      : busy === "inspecting" ? "正在检查恢复状态…" : busy === "planningRecovery" ? "正在准备恢复操作…" : "正在执行一次性事务…"}</p>}
    {error && <p role="alert" className="publish-warning">{error}</p>}

    {shownInstallPlan && projection && <div className="operation-plan">
      <p><strong>安装计划（一次性，5 分钟内有效）</strong></p>
      <p>目标：当前资料库；策略：{strategyLabel(strategy)}；事务上限：1</p>
      <p>投影清单 SHA-256：{projection.manifestSha256}</p>
      <p>资料项：{projection.itemCount}；历史修订：{projection.revisionCount}；分类：{projection.folderCount}；资源文件：{projection.fileCount}；资源字节：{projection.resourceByteSize}</p>
      <p>导入资料项：{projection.importedItems}；导入分类：{projection.importedFolders}；关闭原有权限的新增资料项：{projection.resetPermissionItems}</p>
      <label><input type="checkbox" checked={acknowledged} onChange={event => changeAcknowledgement(event.target.checked)} disabled={busy !== null} />我确认写入当前资料库；导入资料的 AI 与语义索引授权关闭，当前独有资料和旧快照保留。</label>
      <button type="button" onClick={() => void execute()} disabled={!acknowledged || busy !== null}>确认并安装</button>
      <button type="button" onClick={abandonPlan} disabled={busy !== null}>放弃安装计划</button>
    </div>}

    {shownDiagnosis && <div className="operation-plan">
      <p><strong>只读恢复诊断</strong></p>
      <p>状态：{diagnosisLabel[shownDiagnosis.state]}</p>
      {shownDiagnosis.transactionId && <p>事务 ID：{shownDiagnosis.transactionId}</p>}
      <p>资料库访问：{shownDiagnosis.libraryAccessBlocked ? "已阻止" : "可用"}；旧快照：{shownDiagnosis.snapshotRetained ? "已保留" : "未确认"}</p>
      {shownDiagnosis.canCancel && <button type="button" onClick={() => void prepareRecovery("cancel")} disabled={busy !== null}>准备取消计划</button>}
      {shownDiagnosis.canFinalize && <button type="button" onClick={() => void prepareRecovery("finalize")} disabled={busy !== null}>准备完成计划</button>}
      {shownDiagnosis.canRollback && <button type="button" onClick={() => void prepareRecovery("rollback")} disabled={busy !== null}>准备回滚计划</button>}
      {!shownDiagnosis.canCancel && !shownDiagnosis.canFinalize && !shownDiagnosis.canRollback
        && <p className="publish-muted">当前诊断没有可准备的恢复操作。</p>}
    </div>}

    {shownRecoveryPlan && <div className="operation-plan">
      <p><strong>恢复操作计划（一次性，5 分钟内有效）</strong></p>
      <p>操作：{actionLabel[shownRecoveryPlan.action]}；事务 ID：{shownRecoveryPlan.transactionId}</p>
      <label><input type="checkbox" checked={acknowledged} onChange={event => changeAcknowledgement(event.target.checked)} disabled={busy !== null} />我确认执行此恢复操作；已有事务文件不会被删除，完整旧快照是否已形成以只读诊断为准。</label>
      <button type="button" onClick={() => void execute()} disabled={!acknowledged || busy !== null}>确认执行恢复操作</button>
      <button type="button" onClick={abandonPlan} disabled={busy !== null}>放弃恢复计划</button>
    </div>}

    {shownReceipt && <div className="operation-plan">
      <p role="status">{shownReceipt.action === "install" ? "安装已提交" : `${actionLabel[shownReceipt.action]}已完成`}；资料库已由后端自动重新加载。</p>
      <p>事务状态：{diagnosisLabel[shownReceipt.state]}；{shownReceipt.snapshotRetained ? "完整旧快照已保留" : "完整旧快照尚未形成"}；恢复日志已持久化。</p>
      <p>原清单 SHA-256：{shownReceipt.previousManifestSha256}；当前清单 SHA-256：{shownReceipt.projectedManifestSha256}</p>
    </div>}
  </section>;
}
