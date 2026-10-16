import { describe, expect, it, vi } from "vitest";
import type { KnowledgePackageCheckGateway, KnowledgePackageCheckReport, KnowledgePackageMemoryPreflight } from "../contracts/knowledgePackageCheck";

const open = vi.fn();
vi.mock("@tauri-apps/plugin-dialog", () => ({ open }));
import { createRepositoryGateway } from "./repositoryGateway";

const report = {
  reportId: "11111111-1111-4111-8111-111111111111",
  sourcePath: "/tmp/repopress-knowledge-saved-files.json",
  format: "repopress-knowledge-saved-files",
  schemaVersion: 1,
  sourceManifestSchemaVersion: 4,
  scope: "selectedKnowledgePackage",
  itemCount: 1,
  revisionCount: 1,
  bodyFileCount: 1,
  archiveFileCount: 0,
  resourceByteSize: 3,
  byteSize: 100,
  sha256: "a".repeat(64),
  manifestSha256: "b".repeat(64),
  exclusions: [],
  limits: {} as KnowledgePackageCheckReport["limits"],
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
  checkedAtEpochMs: 1,
  expiresAtEpochMs: 2,
} as KnowledgePackageCheckReport;
const preflight = {
  reportId: report.reportId,
  sourcePath: report.sourcePath,
  byteSize: report.byteSize,
  sha256: report.sha256,
  manifestSha256: report.manifestSha256,
  stagedFileCount: 1,
  stagedByteSize: 3,
  staging: "ephemeralMemory",
  sourceRevalidated: true,
  filesystemWrites: false,
  currentLibraryChanged: false,
  restoreReady: false,
} as KnowledgePackageMemoryPreflight;

describe("knowledge package check gateway", () => {
  it("uses the JSON file selector and exact inspect/preflight/discard IPC", async () => {
    open.mockResolvedValueOnce(report.sourcePath);
    const invoke = vi.fn(async <T>(name: string): Promise<T> => {
      if (name === "inspect_knowledge_package") return report as T;
      if (name === "preflight_knowledge_package") return preflight as T;
      if (name === "discard_knowledge_package_check") return undefined as T;
      throw new Error(`unexpected command ${name}`);
    });
    const gateway = createRepositoryGateway(invoke as unknown as <T>(command: string, args?: object) => Promise<T>) as unknown as KnowledgePackageCheckGateway;
    await expect(gateway.selectKnowledgePackageSource()).resolves.toBe(report.sourcePath);
    await expect(gateway.inspectKnowledgePackage(report.sourcePath)).resolves.toEqual(report);
    await expect(gateway.preflightKnowledgePackage(report.reportId)).resolves.toEqual(preflight);
    await expect(gateway.discardKnowledgePackageCheck(report.reportId)).resolves.toBeUndefined();
    expect(open).toHaveBeenCalledWith({ title: "选择资料保存文件 JSON 包", multiple: false, directory: false, filters: [{ name: "资料保存文件备份包", extensions: ["json"] }] });
    expect(invoke).toHaveBeenNthCalledWith(1, "inspect_knowledge_package", { sourcePath: report.sourcePath });
    expect(invoke).toHaveBeenNthCalledWith(2, "preflight_knowledge_package", { reportId: report.reportId });
    expect(invoke).toHaveBeenNthCalledWith(3, "discard_knowledge_package_check", { reportId: report.reportId });
  });

  it("returns null when the native selector is cancelled", async () => {
    open.mockResolvedValueOnce(null);
    const invoke = vi.fn();
    const gateway = createRepositoryGateway(invoke as unknown as <T>(command: string, args?: object) => Promise<T>) as unknown as KnowledgePackageCheckGateway;
    await expect(gateway.selectKnowledgePackageSource()).resolves.toBeNull();
    expect(invoke).not.toHaveBeenCalled();
  });

  it("fails closed for every browser-demo action without IPC", async () => {
    const invoke = vi.fn();
    const gateway = createRepositoryGateway() as unknown as KnowledgePackageCheckGateway;
    await expect(gateway.selectKnowledgePackageSource()).rejects.toMatchObject({ code: "read_only_demo" });
    await expect(gateway.inspectKnowledgePackage(report.sourcePath)).rejects.toMatchObject({ code: "read_only_demo" });
    await expect(gateway.preflightKnowledgePackage(report.reportId)).rejects.toMatchObject({ code: "read_only_demo" });
    await expect(gateway.discardKnowledgePackageCheck(report.reportId)).rejects.toMatchObject({ code: "read_only_demo" });
    expect(invoke).not.toHaveBeenCalled();
  });
});
