import { act, createElement, type ReactElement } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { I18nProvider } from "../i18n/i18n";
import { WorkspaceConfigBackupPanel } from "./WorkspaceConfigBackupPanel";
import { KnowledgeBackupPanel } from "./KnowledgeBackupPanel";
import { RssSnapshotBackupPanel } from "./RssSnapshotBackupPanel";
import { DraftSnapshotBackupPanel } from "./DraftSnapshotBackupPanel";
import type { WorkspaceConfigBackupGateway } from "../contracts/workspaceConfigBackup";
import { WORKSPACE_CONFIG_BACKUP_EXCLUDED_SOURCES } from "../contracts/workspaceConfigBackup";
import { WORKSPACE_BACKUP_EXCLUSIONS } from "../contracts/workspaceBackup";
import { KNOWLEDGE_BACKUP_EXCLUSIONS, KNOWLEDGE_BACKUP_LIMITS, type KnowledgeBackupGateway } from "../contracts/knowledgeBackup";
import { RSS_SNAPSHOT_EXCLUSIONS, RSS_SNAPSHOT_TABLES, type RssSnapshotBackupGateway } from "../contracts/rssSnapshotBackup";
import { DRAFT_SNAPSHOT_EXCLUSIONS, type DraftSnapshotBackupGateway } from "../contracts/draftSnapshotBackup";

Object.assign(globalThis, { IS_REACT_ACT_ENVIRONMENT: true });
const clock = 1_700_000_000_000;
const id = "11111111-1111-4111-8111-111111111111";
const sha = "a".repeat(64);
type Gateway = Record<string, ReturnType<typeof vi.fn>>;
type Scenario = {
  name: string; extension: string; choose: string; preview: string; execute: string; consent: string;
  selectMethod: string; planMethod: string; executeMethod: string; discardMethod: string;
  element: (gateway: Gateway) => ReactElement;
  plan: (path: string) => Record<string, unknown>;
};
const common = (path: string) => ({ planId: id, destinationPath: path, byteSize: 1234, sha256: sha, createdAtEpochMs: clock, expiresAtEpochMs: clock + 300_000, schemaVersion: 1, structureVerified: true });
const scenarios: Scenario[] = [
  { name: "configuration", extension: "json", choose: "Choose a new JSON file path", preview: "Preview configuration backup", execute: "Export configuration backup once", consent: "workspace-config-backup-consent",
    selectMethod: "selectWorkspaceConfigBackupDestination", planMethod: "planWorkspaceConfigBackup", executeMethod: "executeWorkspaceConfigBackup", discardMethod: "discardWorkspaceConfigBackup",
    element: gateway => createElement(WorkspaceConfigBackupPanel, { gateway: gateway as unknown as WorkspaceConfigBackupGateway, enabled: true }),
    plan: path => ({ ...common(path), scope: "applicationPrivateConfiguration", format: "repopress-workspace-config", selectedSources: ["workspace"], sources: [{ source: "workspace", sourceByteSize: 1234, itemCount: 1, recoveryDraftCount: 1 }], excludedSources: [...WORKSPACE_CONFIG_BACKUP_EXCLUDED_SOURCES], exclusions: [...WORKSPACE_BACKUP_EXCLUSIONS], consistentSnapshot: false, includesCredentials: false }),
  },
  { name: "knowledge", extension: "json", choose: "Choose a new knowledge JSON file path", preview: "Preview knowledge backup", execute: "Export knowledge backup once", consent: "knowledge-backup-consent",
    selectMethod: "selectKnowledgeBackupDestination", planMethod: "planKnowledgeBackup", executeMethod: "executeKnowledgeBackup", discardMethod: "discardKnowledgeBackup",
    element: gateway => createElement(KnowledgeBackupPanel, { gateway: gateway as unknown as KnowledgeBackupGateway, enabled: true }),
    plan: path => ({ ...common(path), scope: "applicationSavedKnowledge", format: "repopress-knowledge-saved-files", sourceManifestSchemaVersion: 4, itemCount: 1, revisionCount: 1, bodyFileCount: 1, archiveFileCount: 0, resourceByteSize: 1234, exclusions: [...KNOWLEDGE_BACKUP_EXCLUSIONS], limits: KNOWLEDGE_BACKUP_LIMITS, contentVerified: true, allSavedReferencesIncluded: true, consistentSnapshot: false, includesCredentialStores: false, includesCompletedOperations: false, externalReferencesIncluded: false }),
  },
  { name: "RSS", extension: "sqlite", choose: "Choose a new SQLite file path", preview: "Preview RSS snapshot", execute: "Export RSS snapshot once", consent: "rss-snapshot-backup-consent",
    selectMethod: "selectRssSnapshotBackupDestination", planMethod: "planRssSnapshotBackup", executeMethod: "executeRssSnapshotBackup", discardMethod: "discardRssSnapshotBackup",
    element: gateway => createElement(RssSnapshotBackupPanel, { gateway: gateway as unknown as RssSnapshotBackupGateway, enabled: true }),
    plan: path => ({ ...common(path), scope: "applicationRssDatabase", format: "sqlite3", databaseSchemaVersion: 4, tables: RSS_SNAPSHOT_TABLES.map(table => ({ table, rowCount: 1234 })), exclusions: [...RSS_SNAPSHOT_EXCLUSIONS], consistentSnapshot: true, includesCredentialStores: false, includesUndoActions: true, compactedCopy: true }),
  },
  { name: "drafts", extension: "sqlite", choose: "Choose a new draft SQLite file path", preview: "Preview draft snapshot", execute: "Export draft snapshot once", consent: "draft-snapshot-backup-consent",
    selectMethod: "selectDraftSnapshotBackupDestination", planMethod: "planDraftSnapshotBackup", executeMethod: "executeDraftSnapshotBackup", discardMethod: "discardDraftSnapshotBackup",
    element: gateway => createElement(DraftSnapshotBackupPanel, { gateway: gateway as unknown as DraftSnapshotBackupGateway, enabled: true }),
    plan: path => ({ ...common(path), scope: "applicationDraftDatabase", format: "sqlite3", source: "generalDrafts", sourceSchema: "unversionedInstalledLayout", tables: [{ table: "general_drafts", rowCount: 1234 }], exclusions: [...DRAFT_SNAPSHOT_EXCLUSIONS], contentVerified: true, consistentSnapshot: true, multiDatabaseSnapshot: false, includesCredentialStores: false, includesRecycledDrafts: false, compactedCopy: true }),
  },
];
function deferred<T>() { let resolve!: (value: T) => void; const promise = new Promise<T>(done => { resolve = done; }); return { promise, resolve }; }
let host: HTMLDivElement; let root: ReturnType<typeof createRoot>;
const settle = () => act(async () => { await Promise.resolve(); await Promise.resolve(); });
const render = (scenario: Scenario, gateway: Gateway, locale: "zh-CN" | "en-US") => act(() => root.render(createElement(I18nProvider, { locale, children: scenario.element(gateway) })));
function button(label: string) { const value = [...host.querySelectorAll<HTMLButtonElement>("button")].find(item => item.textContent === label); if (!value) throw new Error(`Missing ${label}`); return value; }
async function click(label: string) { await act(async () => button(label).click()); await settle(); }
function fixture(scenario: Scenario) {
  const path = `/tmp/设置-{bytes}.${scenario.extension}`; const plan = scenario.plan(path);
  const receipt = { planId: id, destinationPath: path, byteSize: 1234, sha256: sha, ...(plan.selectedSources ? { selectedSources: plan.selectedSources } : {}), ...(plan.source ? { source: plan.source } : {}) };
  const gateway: Gateway = { [scenario.selectMethod]: vi.fn(async () => path), [scenario.planMethod]: vi.fn(async () => plan), [scenario.executeMethod]: vi.fn(async () => receipt), [scenario.discardMethod]: vi.fn(async () => undefined) };
  return { path, plan, receipt, gateway };
}
beforeEach(() => { vi.useFakeTimers(); vi.setSystemTime(clock); host = document.createElement("div"); document.body.append(host); root = createRoot(host); });
afterEach(() => { act(() => root.unmount()); host.remove(); vi.useRealTimers(); });

describe("backup export live localization", () => {
  it.each(scenarios)("keeps $name pending plans, consent and one-time execute stable while translating local receipts", async scenario => {
    const { gateway, path, plan, receipt } = fixture(scenario); const pendingPlan = deferred<Record<string, unknown>>(); const pendingReceipt = deferred<Record<string, unknown>>();
    gateway[scenario.planMethod].mockReturnValueOnce(pendingPlan.promise); gateway[scenario.executeMethod].mockReturnValueOnce(pendingReceipt.promise);
    render(scenario, gateway, "en-US"); await click(scenario.choose); await click(scenario.preview);
    render(scenario, gateway, "zh-CN"); render(scenario, gateway, "en-US");
    expect(gateway[scenario.selectMethod]).toHaveBeenCalledTimes(1); expect(gateway[scenario.planMethod]).toHaveBeenCalledTimes(1); expect(gateway[scenario.discardMethod]).not.toHaveBeenCalled();
    await act(async () => pendingPlan.resolve(plan)); await settle();
    expect(host.textContent).toContain(path); expect(host.textContent).toContain(sha); expect(host.textContent).toContain("1,234"); expect(host.textContent).toContain(new Date(clock + 300_000).toLocaleString("en-US"));
    const consent = host.querySelector<HTMLInputElement>(`#${scenario.consent}`)!;
    expect(button(scenario.execute).disabled).toBe(true); await act(async () => consent.click());
    render(scenario, gateway, "zh-CN"); expect(host.querySelector(`#${scenario.consent}`)).toBe(consent); expect(consent.checked).toBe(true); expect(host.textContent).toContain(new Date(clock + 300_000).toLocaleString("zh-CN"));
    render(scenario, gateway, "en-US"); const execute = button(scenario.execute);
    await act(async () => { execute.click(); execute.click(); }); render(scenario, gateway, "zh-CN");
    expect(gateway[scenario.executeMethod]).toHaveBeenCalledTimes(1); expect(gateway[scenario.executeMethod]).toHaveBeenCalledWith(id, true);
    await act(async () => pendingReceipt.resolve(receipt)); await settle(); expect(host.querySelector('[role="status"]')?.textContent).toContain("已导出并核验");
    render(scenario, gateway, "en-US"); expect(host.querySelector('[role="status"]')?.textContent).toContain("Exported and verified"); expect(host.querySelector('[role="status"]')?.textContent).toContain(path); expect(host.querySelector('[role="status"]')?.textContent).toContain(sha);
    expect(gateway[scenario.planMethod]).toHaveBeenCalledTimes(1); expect(gateway[scenario.discardMethod]).not.toHaveBeenCalled();
  });

  it.each(scenarios)("keeps $name original expiry and safe local errors through locale changes", async scenario => {
    const { gateway } = fixture(scenario); render(scenario, gateway, "en-US"); await click(scenario.choose); await click(scenario.preview);
    const oldExecute = button(scenario.execute); const consent = host.querySelector<HTMLInputElement>(`#${scenario.consent}`)!; await act(async () => consent.click());
    await act(async () => vi.advanceTimersByTime(200_000)); render(scenario, gateway, "zh-CN"); render(scenario, gateway, "en-US");
    expect(gateway[scenario.discardMethod]).not.toHaveBeenCalled(); expect(consent.checked).toBe(true);
    await act(async () => vi.advanceTimersByTime(100_001)); expect(host.querySelector(`#${scenario.consent}`)).toBeNull(); expect(gateway[scenario.discardMethod]).toHaveBeenCalledWith(id);
    expect(host.querySelector('[role="alert"]')?.textContent).toContain("expired"); render(scenario, gateway, "zh-CN"); expect(host.querySelector('[role="alert"]')?.textContent).toContain("计划已过期，请重新生成。");
    await act(async () => oldExecute.click()); expect(gateway[scenario.executeMethod]).not.toHaveBeenCalled();
    render(scenario, gateway, "en-US"); gateway[scenario.selectMethod].mockRejectedValueOnce(new Error("计划已过期，请重新生成。 private-transport-secret")); await click(scenario.choose);
    expect(host.querySelector('[role="alert"]')?.textContent).toContain("Unable to select"); expect(host.textContent).not.toContain("private-transport-secret");
    render(scenario, gateway, "zh-CN"); expect(host.querySelector('[role="alert"]')?.textContent).toContain("无法选择新的"); expect(gateway[scenario.planMethod]).toHaveBeenCalledTimes(1);
  });
});
