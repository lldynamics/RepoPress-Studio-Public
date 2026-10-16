import { act, createElement } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  WORKSPACE_BACKUP_EXCLUSIONS,
  WORKSPACE_BACKUP_SOURCES,
  type WorkspaceBackupGateway,
  type WorkspaceBackupReport,
  type WorkspaceBackupSource,
} from "../contracts/workspaceBackup";
import {
  KNOWLEDGE_INTEGRITY_EXCLUSIONS,
  KNOWLEDGE_INTEGRITY_LIMITS,
  type KnowledgeIntegrityGateway,
  type KnowledgeIntegrityReport,
  type KnowledgeIntegrityRecheck,
} from "../contracts/knowledgeIntegrity";
import { I18nProvider } from "../i18n/i18n";
import type { UiLocale } from "../i18n/locale";
import { KnowledgeIntegrityPanel } from "./KnowledgeIntegrityPanel";
import { WorkspaceBackupPreflightPanel } from "./WorkspaceBackupPreflightPanel";

const clock = 1_700_000_000_000;
const firstWorkspaceId = "11111111-1111-4111-8111-111111111111";
const firstKnowledgeId = "22222222-2222-4222-8222-222222222222";
const secondKnowledgeId = "33333333-3333-4333-8333-333333333333";

function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (reason?: unknown) => void;
  const promise = new Promise<T>((resolvePromise, rejectPromise) => { resolve = resolvePromise; reject = rejectPromise; });
  return { promise, resolve, reject };
}

function workspaceReport(selectedSources: WorkspaceBackupSource[], reportId = firstWorkspaceId): WorkspaceBackupReport {
  return {
    reportId,
    schemaVersion: 1,
    scope: "applicationPrivateData",
    checkedAtEpochMs: clock,
    expiresAtEpochMs: clock + 300_000,
    selectedSources,
    sources: selectedSources.map((source) => source === "draftHistory"
      ? { source, status: "limited", fileCount: 1, byteCount: 1_234_567, omittedEntries: 1_234, issues: ["entryLimit", "byteLimit"], requiresDatabaseSnapshot: true }
      : { source, status: "metadataOnly", fileCount: source === "knowledge" ? 1_234 : 1, byteCount: 1_234_567, omittedEntries: 0, issues: [], requiresDatabaseSnapshot: ["rss", "generalDrafts"].includes(source) }),
    exclusions: [...WORKSPACE_BACKUP_EXCLUSIONS],
    contentVerified: false,
    consistentSnapshot: false,
  };
}

function knowledgeReport(reportId = firstKnowledgeId, partial = false): KnowledgeIntegrityReport {
  return {
    reportId,
    schemaVersion: 1,
    scope: "applicationKnowledgeReferences",
    checkedAtEpochMs: clock,
    expiresAtEpochMs: clock + 300_000,
    status: partial ? "partial" : "checked",
    manifestState: "verified",
    manifestSchemaVersion: 4,
    manifestSha256: "a".repeat(64),
    itemCount: 1_234,
    revisionCount: 1_234,
    resources: [
      { kind: "body", referenceCount: 1_234, uniqueFiles: 2, verified: partial ? 1 : 2, missing: partial ? 1 : 0, unsafe: 0, unreadable: 0, invalid: 0, changed: 0, omitted: 0, verifiedBytes: 1_234_567 },
      { kind: "archive", referenceCount: 2, uniqueFiles: 2, verified: 2, missing: 0, unsafe: 0, unreadable: 0, invalid: 0, changed: 0, omitted: 0, verifiedBytes: 765_432 },
    ],
    archiveMissingResources: 0,
    archiveTruncated: 0,
    archiveUnknownCompleteness: 0,
    issues: partial ? ["missingFile", "changedDuringRead"] : [],
    exclusions: [...KNOWLEDGE_INTEGRITY_EXCLUSIONS],
    limits: KNOWLEDGE_INTEGRITY_LIMITS,
    allReferencedFilesVerified: !partial,
    consistentSnapshot: false,
    backupReady: false,
  };
}

type WorkspaceGatewayMock = { [K in keyof WorkspaceBackupGateway]: ReturnType<typeof vi.fn> };
type KnowledgeGatewayMock = { [K in keyof KnowledgeIntegrityGateway]: ReturnType<typeof vi.fn> };
let host: HTMLDivElement;
let root: ReturnType<typeof createRoot>;

async function settle() { await act(async () => { await Promise.resolve(); await Promise.resolve(); }); }
function button(pattern: RegExp) { return [...host.querySelectorAll("button")].find((item) => pattern.test(item.textContent ?? "")) as HTMLButtonElement | undefined; }
async function click(pattern: RegExp) { const target = button(pattern); expect(target).toBeDefined(); await act(async () => target!.click()); await settle(); }

describe("backup preflight localization lifecycle", () => {
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

  it("keeps selected sources and one pending workspace inspection across zh-en-zh", async () => {
    const pending = deferred<WorkspaceBackupReport>();
    const gateway = {
      inspectWorkspaceBackup: vi.fn(() => pending.promise),
      recheckWorkspaceBackup: vi.fn(),
      discardWorkspaceBackup: vi.fn(async () => undefined),
    } as WorkspaceGatewayMock;
    const render = async (locale: UiLocale) => act(async () => root.render(createElement(I18nProvider, { locale, children: createElement(WorkspaceBackupPreflightPanel, { gateway: gateway as unknown as WorkspaceBackupGateway, enabled: true }) })));

    await render("zh-CN");
    const rss = [...host.querySelectorAll("label")].find((item) => item.textContent === "RSS")!.querySelector("input")!;
    await act(async () => rss.click());
    await click(/检查备份范围/);
    const selected = WORKSPACE_BACKUP_SOURCES.filter((source) => source !== "rss");
    expect(gateway.inspectWorkspaceBackup).toHaveBeenCalledWith(selected);
    await render("en-US");
    expect(host.textContent).toContain("Checking the selected backup scope");
    expect(rss.checked).toBe(false);
    await render("zh-CN");
    expect(host.textContent).toContain("正在检查所选备份范围");
    expect(gateway.inspectWorkspaceBackup).toHaveBeenCalledTimes(1);
    expect(gateway.discardWorkspaceBackup).not.toHaveBeenCalled();

    pending.resolve(workspaceReport(selected));
    await settle();
    expect(host.textContent).toContain(firstWorkspaceId);
    expect(host.textContent).toContain(new Date(clock + 300_000).toLocaleString("zh-CN"));
    expect(rss.checked).toBe(false);
  });

  it("relocalizes workspace fields and expiry errors without rescanning, discarding, or extending TTL", async () => {
    const report = workspaceReport([...WORKSPACE_BACKUP_SOURCES]);
    const gateway = {
      inspectWorkspaceBackup: vi.fn(async () => report),
      recheckWorkspaceBackup: vi.fn(),
      discardWorkspaceBackup: vi.fn(async () => undefined),
    } as WorkspaceGatewayMock;
    const render = async (locale: UiLocale) => act(async () => root.render(createElement(I18nProvider, { locale, children: createElement(WorkspaceBackupPreflightPanel, { gateway: gateway as unknown as WorkspaceBackupGateway, enabled: true }) })));

    await render("zh-CN");
    await click(/检查备份范围/);
    expect(host.textContent).toContain("条目数量达到上限、字节数达到上限");
    expect(host.textContent).toContain("凭据（Secret Service，不查询）；加密聊天内容");
    await render("en-US");
    expect(host.textContent).toContain("Physical files");
    const knowledge = [...host.querySelectorAll("article")].find((item) => item.querySelector("h5")?.textContent === "Knowledge base");
    expect(knowledge?.textContent).toContain("Physical files1,234");
    expect(host.textContent).toContain("Issues: Entry limit reached, Byte limit reached");
    expect(host.textContent).toContain(new Date(clock + 300_000).toLocaleString("en-US"));
    await render("zh-CN");
    expect(host.textContent).toContain(firstWorkspaceId);
    expect(gateway.inspectWorkspaceBackup).toHaveBeenCalledTimes(1);
    expect(gateway.discardWorkspaceBackup).not.toHaveBeenCalled();

    await act(async () => vi.advanceTimersByTime(299_999));
    expect(host.textContent).toContain(firstWorkspaceId);
    await act(async () => vi.advanceTimersByTime(1));
    expect(gateway.discardWorkspaceBackup).toHaveBeenCalledTimes(1);
    expect(gateway.discardWorkspaceBackup).toHaveBeenCalledWith(firstWorkspaceId);
    expect(host.textContent).toContain("清单已过期");
    await render("en-US");
    expect(host.textContent).toContain("The inventory expired");
    expect(gateway.inspectWorkspaceBackup).toHaveBeenCalledTimes(1);
    expect(gateway.discardWorkspaceBackup).toHaveBeenCalledTimes(1);
  });

  it("keeps a pending knowledge recheck and its report binding across zh-en-zh", async () => {
    const pending = deferred<KnowledgeIntegrityRecheck>();
    const initial = knowledgeReport();
    const next = knowledgeReport(secondKnowledgeId, true);
    const gateway = {
      inspectKnowledgeIntegrity: vi.fn(async () => initial),
      recheckKnowledgeIntegrity: vi.fn(() => pending.promise),
      discardKnowledgeIntegrity: vi.fn(async () => undefined),
    } as KnowledgeGatewayMock;
    const render = async (locale: UiLocale) => act(async () => root.render(createElement(I18nProvider, { locale, children: createElement(KnowledgeIntegrityPanel, { gateway: gateway as unknown as KnowledgeIntegrityGateway, enabled: true }) })));

    await render("zh-CN");
    await click(/明确检查资料引用/);
    await render("en-US");
    expect(host.textContent).toContain("Manifest: Verified");
    expect(host.textContent).toContain("Items: 1,234; revisions: 1,234");
    expect(host.textContent).toContain(new Date(clock + 300_000).toLocaleString("en-US"));
    await render("zh-CN");
    await click(/明确重新核对资料引用/);
    expect(gateway.recheckKnowledgeIntegrity).toHaveBeenCalledWith(firstKnowledgeId);
    await render("en-US");
    expect(host.textContent).toContain("Rechecking knowledge references");
    await render("zh-CN");
    expect(host.textContent).toContain("正在重新核对资料引用");
    expect(gateway.recheckKnowledgeIntegrity).toHaveBeenCalledTimes(1);
    expect(gateway.discardKnowledgeIntegrity).not.toHaveBeenCalled();

    pending.resolve({ report: next, comparison: "inconclusive" });
    await settle();
    await render("en-US");
    expect(host.textContent).toContain("Issues: Referenced file missing, Changed during read");
    expect(host.textContent).toContain("Fixed exclusions: Credentials, Other workspace sources");
    expect(host.textContent).toContain("Recheck result: Inconclusive");
    expect(gateway.recheckKnowledgeIntegrity).toHaveBeenCalledTimes(1);
    expect(gateway.discardKnowledgeIntegrity).not.toHaveBeenCalled();
  });

  it("renders a pending knowledge inspection failure in the current locale without repeating it", async () => {
    const pending = deferred<KnowledgeIntegrityReport>();
    const gateway = {
      inspectKnowledgeIntegrity: vi.fn(() => pending.promise),
      recheckKnowledgeIntegrity: vi.fn(),
      discardKnowledgeIntegrity: vi.fn(async () => undefined),
    } as KnowledgeGatewayMock;
    const render = async (locale: UiLocale) => act(async () => root.render(createElement(I18nProvider, { locale, children: createElement(KnowledgeIntegrityPanel, { gateway: gateway as unknown as KnowledgeIntegrityGateway, enabled: true }) })));

    await render("zh-CN");
    await click(/明确检查资料引用/);
    await render("en-US");
    expect(host.textContent).toContain("Checking knowledge references");
    pending.reject(new Error("unavailable"));
    await settle();
    expect(host.textContent).toContain("Unable to check knowledge references");
    await render("zh-CN");
    expect(host.textContent).toContain("无法检查资料引用");
    expect(gateway.inspectKnowledgeIntegrity).toHaveBeenCalledTimes(1);
    expect(gateway.discardKnowledgeIntegrity).not.toHaveBeenCalled();
  });
});
