import { act, createElement } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  KNOWLEDGE_PACKAGE_CHECK_EXCLUSIONS,
  KNOWLEDGE_PACKAGE_CHECK_LIMITS,
  type KnowledgePackageCheckReport,
} from "../contracts/knowledgePackageCheck";
import {
  KNOWLEDGE_PACKAGE_STAGE_LIMITS,
  type KnowledgePackageStageGateway,
  type KnowledgePackageStagePlan,
  type KnowledgePackageStageResult,
} from "../contracts/knowledgePackageStage";
import { I18nProvider } from "../i18n/i18n";
import type { UiLocale } from "../i18n/locale";
import { KnowledgePackageStagePanel } from "./KnowledgePackageStagePanel";

const clock = 1_700_000_000_000;
const planId = "11111111-1111-4111-8111-111111111111";
const sourcePath = "/tmp/资料-{sourcePath}-{sha256}.json";
const parentPath = "/tmp/候选-{parentPath}";
const candidatePath = `${parentPath}/repopress-knowledge-stage-${planId}`;
const packageSha = "a".repeat(64);
const manifestSha = "b".repeat(64);
const inventorySha = "c".repeat(64);

function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (reason?: unknown) => void;
  const promise = new Promise<T>((resolvePromise, rejectPromise) => { resolve = resolvePromise; reject = rejectPromise; });
  return { promise, resolve, reject };
}

function report(): KnowledgePackageCheckReport {
  return {
    reportId: planId,
    sourcePath,
    format: "repopress-knowledge-saved-files",
    schemaVersion: 1,
    sourceManifestSchemaVersion: 4,
    scope: "selectedKnowledgePackage",
    itemCount: 1_234,
    revisionCount: 2_345,
    bodyFileCount: 600,
    archiveFileCount: 400,
    resourceByteSize: 1_234_567,
    byteSize: 2_345_678,
    sha256: packageSha,
    manifestSha256: manifestSha,
    exclusions: [...KNOWLEDGE_PACKAGE_CHECK_EXCLUSIONS],
    limits: KNOWLEDGE_PACKAGE_CHECK_LIMITS,
    structureVerified: true,
    contentVerified: true,
    allSavedReferencesIncluded: true,
    sourceManifestHashVerified: false,
    consistentSnapshot: false,
    includesCredentialStores: false,
    includesCompletedOperations: false,
    externalReferencesIncluded: false,
    filesystemWrites: false,
    currentLibraryChanged: false,
    restoreReady: false,
    checkedAtEpochMs: clock,
    expiresAtEpochMs: clock + 300_000,
  };
}

function plan(): KnowledgePackageStagePlan {
  return {
    planId,
    sourcePath,
    parentPath,
    candidatePath,
    format: "repopress-knowledge-isolated-candidate",
    schemaVersion: 1,
    package: report(),
    candidateFileCount: 1_002,
    candidateByteSize: 2_345_678,
    candidateInventorySha256: inventorySha,
    limits: KNOWLEDGE_PACKAGE_STAGE_LIMITS,
    requiresSensitivePlaintextConsent: true,
    candidateOnly: true,
    currentLibraryChanged: false,
    restoreReady: false,
    createdAtEpochMs: clock,
    expiresAtEpochMs: clock + 300_000,
  };
}

function result(): KnowledgePackageStageResult {
  return {
    planId,
    sourcePath,
    candidatePath,
    packageSha256: packageSha,
    manifestSha256: manifestSha,
    candidateFileCount: 1_002,
    candidateByteSize: 2_345_678,
    candidateInventorySha256: inventorySha,
    privatePermissionsVerified: true,
    contentsVerified: true,
    sourceRevalidated: true,
    candidateOnly: true,
    currentLibraryChanged: false,
    restoreReady: false,
  };
}

type GatewayMock = { [K in keyof KnowledgePackageStageGateway]: ReturnType<typeof vi.fn> };
let host: HTMLDivElement;
let root: ReturnType<typeof createRoot>;

function gatewayWith(overrides: Partial<GatewayMock> = {}): GatewayMock {
  return {
    selectKnowledgePackageStageSource: vi.fn(async () => sourcePath),
    selectKnowledgePackageStageParent: vi.fn(async () => parentPath),
    planKnowledgePackageStage: vi.fn(async () => plan()),
    executeKnowledgePackageStage: vi.fn(async () => result()),
    discardKnowledgePackageStage: vi.fn(async () => undefined),
    ...overrides,
  } as GatewayMock;
}

async function render(gateway: GatewayMock, locale: UiLocale) {
  await act(async () => root.render(createElement(I18nProvider, {
    locale,
    children: createElement(KnowledgePackageStagePanel, { gateway: gateway as unknown as KnowledgePackageStageGateway, enabled: true }),
  })));
}

async function settle() { await act(async () => { await Promise.resolve(); await Promise.resolve(); }); }
function button(pattern: RegExp) { return [...host.querySelectorAll("button")].find((item) => pattern.test(item.textContent ?? "")) as HTMLButtonElement | undefined; }
async function click(pattern: RegExp) { const target = button(pattern); expect(target).toBeDefined(); await act(async () => target!.click()); await settle(); }
async function selectInputs() { await click(/选择资料 JSON 文件/); await click(/选择候选文件夹/); }
async function preparePlan() { await selectInputs(); await click(/生成候选预览/); }

describe("KnowledgePackageStagePanel localization lifecycle", () => {
  Object.assign(globalThis, { IS_REACT_ACT_ENVIRONMENT: true });

  beforeEach(() => {
    vi.useFakeTimers();
    vi.setSystemTime(clock);
    host = document.createElement("div");
    document.body.append(host);
    root = createRoot(host);
  });

  afterEach(() => {
    act(() => root.unmount());
    host.remove();
    vi.useRealTimers();
  });

  it("keeps one pending source selection across zh-en-zh and preserves literal path tokens", async () => {
    const pending = deferred<string | null>();
    const gateway = gatewayWith({ selectKnowledgePackageStageSource: vi.fn(() => pending.promise) });

    await render(gateway, "zh-CN");
    await click(/选择资料 JSON 文件/);
    expect(gateway.selectKnowledgePackageStageSource).toHaveBeenCalledWith();
    await render(gateway, "en-US");
    expect(host.querySelector("section")?.getAttribute("aria-label")).toBe("Knowledge candidate copy");
    expect(host.textContent).toContain("Selecting knowledge JSON file");
    await render(gateway, "zh-CN");
    expect(host.textContent).toContain("正在选择资料 JSON 文件");
    expect(gateway.selectKnowledgePackageStageSource).toHaveBeenCalledTimes(1);
    expect(gateway.discardKnowledgePackageStage).not.toHaveBeenCalled();

    pending.resolve(sourcePath);
    await settle();
    expect(host.textContent).toContain(`来源路径：${sourcePath}`);
    expect((host.textContent?.split(sourcePath).length ?? 1) - 1).toBe(1);
    expect(host.textContent).toContain("{sourcePath}");
    expect(host.textContent).toContain("{sha256}");
  });

  it("relocalizes one pending plan while consent and the original five-minute TTL remain bound", async () => {
    const pending = deferred<KnowledgePackageStagePlan>();
    const gateway = gatewayWith({ planKnowledgePackageStage: vi.fn(() => pending.promise) });

    await render(gateway, "zh-CN");
    await selectInputs();
    await click(/生成候选预览/);
    expect(gateway.planKnowledgePackageStage).toHaveBeenCalledWith(sourcePath, parentPath);
    await render(gateway, "en-US");
    expect(host.textContent).toContain("Creating candidate preview");
    expect(host.textContent).toContain(`Source path: ${sourcePath}`);
    expect(host.textContent).toContain(`Candidate parent folder: ${parentPath}`);
    await render(gateway, "zh-CN");
    expect(host.textContent).toContain("正在生成候选预览");
    expect(gateway.planKnowledgePackageStage).toHaveBeenCalledTimes(1);
    expect(gateway.discardKnowledgePackageStage).not.toHaveBeenCalled();

    pending.resolve(plan());
    await settle();
    const consent = host.querySelector("input[type=checkbox]") as HTMLInputElement;
    await act(async () => consent.click());
    expect(consent.checked).toBe(true);
    await render(gateway, "en-US");
    expect((host.querySelector("input[type=checkbox]") as HTMLInputElement).checked).toBe(true);
    expect(host.textContent).toContain("Knowledge items: 1,234; historical revisions: 2,345; files: 1,002; size: 2,345,678 bytes");
    expect(host.textContent).toContain(new Date(clock).toLocaleString("en-US"));
    expect(host.textContent).toContain(new Date(clock + 300_000).toLocaleString("en-US"));
    expect(host.textContent).toContain(`Candidate inventory SHA-256: ${inventorySha}`);
    expect(host.textContent).toContain(`Package SHA-256: ${packageSha}; package manifest SHA-256: ${manifestSha}`);

    await act(async () => vi.advanceTimersByTime(299_999));
    expect(gateway.discardKnowledgePackageStage).not.toHaveBeenCalled();
    expect((host.querySelector("input[type=checkbox]") as HTMLInputElement).checked).toBe(true);
    await render(gateway, "zh-CN");
    expect(host.textContent).toContain("候选预览（一次性，5 分钟内有效）");
    expect(host.textContent).toContain(new Date(clock).toLocaleString("zh-CN"));
    expect(host.textContent).toContain(new Date(clock + 300_000).toLocaleString("zh-CN"));
    await act(async () => vi.advanceTimersByTime(1));
    expect(gateway.discardKnowledgePackageStage).toHaveBeenCalledTimes(1);
    expect(gateway.discardKnowledgePackageStage).toHaveBeenCalledWith(planId);
    expect(host.textContent).toContain("计划已过期，请重新生成。");
    expect(host.querySelector("input[type=checkbox]")).toBeNull();
  });

  it("keeps one consumed execution across zh-en-zh and renders every verified result field", async () => {
    const pending = deferred<KnowledgePackageStageResult>();
    const gateway = gatewayWith({ executeKnowledgePackageStage: vi.fn(() => pending.promise) });

    await render(gateway, "zh-CN");
    await preparePlan();
    await act(async () => (host.querySelector("input[type=checkbox]") as HTMLInputElement).click());
    await click(/明确创建一次性候选副本/);
    expect(gateway.executeKnowledgePackageStage).toHaveBeenCalledWith(planId, true);
    await render(gateway, "en-US");
    expect(host.textContent).toContain("Creating and verifying candidate copy");
    await render(gateway, "zh-CN");
    expect(host.textContent).toContain("正在创建并核验候选副本");
    expect(gateway.executeKnowledgePackageStage).toHaveBeenCalledTimes(1);
    expect(gateway.discardKnowledgePackageStage).not.toHaveBeenCalled();

    pending.resolve(result());
    await settle();
    await render(gateway, "en-US");
    expect(host.textContent).toContain("Candidate copy created and verified");
    expect(host.textContent).toContain(`Source: ${sourcePath}`);
    expect(host.textContent).toContain(`Candidate path: ${candidatePath}`);
    expect(host.textContent).toContain(`Package SHA-256: ${packageSha}; manifest SHA-256: ${manifestSha}`);
    expect(host.textContent).toContain(`Candidate inventory SHA-256: ${inventorySha}; files: 1,002; size: 2,345,678 bytes`);
    expect(host.textContent).toContain("Private permissions and contents were verified");
    const paragraphs = [...host.querySelectorAll("p")].map((item) => item.textContent);
    expect(paragraphs).toContain(`Source: ${sourcePath}`);
    expect(paragraphs).toContain(`Candidate path: ${candidatePath}`);
    expect((host.textContent?.split(candidatePath).length ?? 1) - 1).toBe(1);
    expect(host.textContent).toContain("{sourcePath}");
    expect(host.textContent).toContain("{parentPath}");
    expect(gateway.executeKnowledgePackageStage).toHaveBeenCalledTimes(1);
  });

  it("renders a delayed consumed-execution error in the current locale with the unchanged candidate path", async () => {
    const pending = deferred<KnowledgePackageStageResult>();
    const gateway = gatewayWith({ executeKnowledgePackageStage: vi.fn(() => pending.promise) });

    await render(gateway, "zh-CN");
    await preparePlan();
    await act(async () => (host.querySelector("input[type=checkbox]") as HTMLInputElement).click());
    await click(/明确创建一次性候选副本/);
    await render(gateway, "en-US");
    pending.reject(new Error("fixture-secret transport failure"));
    await settle();
    const alert = host.querySelector("[role=alert]");
    expect(alert?.textContent).toBe(`The candidate-copy result is inconclusive; the plan was consumed and will not be retried automatically. Check the candidate folder. Candidate path: ${candidatePath}`);
    expect(alert?.textContent).not.toContain("fixture-secret");
    expect((alert?.textContent?.split(candidatePath).length ?? 1) - 1).toBe(1);
    await render(gateway, "zh-CN");
    expect(host.querySelector("[role=alert]")?.textContent).toBe(`候选副本结果未明；计划已消耗，不会自动重试。请检查候选文件夹。 候选路径：${candidatePath}`);
    expect(gateway.executeKnowledgePackageStage).toHaveBeenCalledTimes(1);
    expect(gateway.executeKnowledgePackageStage).toHaveBeenCalledWith(planId, true);
    expect(gateway.discardKnowledgePackageStage).not.toHaveBeenCalled();
  });
});
