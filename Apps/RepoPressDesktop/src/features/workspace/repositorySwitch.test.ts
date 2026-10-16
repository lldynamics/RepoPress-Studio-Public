import { describe, expect, it, vi } from "vitest";
import type { RepositoryGateway, RepositorySessionSnapshot } from "../../contracts/repository";
import { prepareRepositorySwitch } from "./repositorySwitch";

const repository: RepositorySessionSnapshot = { sessionId: "fresh-session", rootPath: "/站点/乙", displayName: "乙", siteKind: "hugo", contentRoot: "content", isGitRepository: true, warnings: [] };
function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((done) => { resolve = done; });
  return { promise, resolve };
}

describe("repository switch preparation", () => {
  it("opens saved sites by ID and scans the fresh session, without trusting a displayed path", async () => {
    const openSiteProfile = vi.fn().mockResolvedValue(repository);
    const openRepository = vi.fn();
    const listMarkdownFiles = vi.fn().mockResolvedValue([]);
    const gateway = { openSiteProfile, openRepository, listMarkdownFiles } as unknown as RepositoryGateway;
    const prepared = await prepareRepositorySwitch(gateway, { kind: "profile", profileId: "site-b" }, null, () => true);
    expect(openSiteProfile).toHaveBeenCalledWith("site-b");
    expect(openRepository).not.toHaveBeenCalled();
    expect(listMarkdownFiles).toHaveBeenCalledWith("fresh-session");
    expect(prepared).toEqual({ repository, files: [], document: null, restoreFailed: false });
  });

  it("never opens a target after the caller denies or invalidates the switch", async () => {
    const openSiteProfile = vi.fn();
    expect(await prepareRepositorySwitch({ openSiteProfile } as unknown as RepositoryGateway, { kind: "profile", profileId: "site-b" }, null, () => false)).toBeNull();
    expect(openSiteProfile).not.toHaveBeenCalled();
  });

  it("stops after a delayed open when a newer request or editor change invalidates it", async () => {
    const pending = deferred<RepositorySessionSnapshot>();
    const listMarkdownFiles = vi.fn();
    let current = true;
    const gateway = { openSiteProfile: vi.fn().mockReturnValue(pending.promise), listMarkdownFiles } as unknown as RepositoryGateway;
    const result = prepareRepositorySwitch(gateway, { kind: "profile", profileId: "old-choice" }, null, () => current);
    current = false;
    pending.resolve(repository);
    expect(await result).toBeNull();
    expect(listMarkdownFiles).not.toHaveBeenCalled();
  });

  it("discards a finished scan if the editor changes while it runs", async () => {
    const pending = deferred<[]>();
    let text = "old text";
    const gateway = { openSiteProfile: vi.fn().mockResolvedValue(repository), listMarkdownFiles: vi.fn().mockReturnValue(pending.promise), openDocument: vi.fn() } as unknown as RepositoryGateway;
    const result = prepareRepositorySwitch(gateway, { kind: "profile", profileId: "site-b" }, "content/old.md", () => text === "old text");
    await Promise.resolve();
    text = "new user input";
    pending.resolve([]);
    expect(await result).toBeNull();
    expect(gateway.openDocument).not.toHaveBeenCalled();
    expect(text).toBe("new user input");
  });

  it("keeps path-based startup restoration and reports an unavailable last document", async () => {
    const gateway = { openRepository: vi.fn().mockResolvedValue(repository), listMarkdownFiles: vi.fn().mockResolvedValue([]), openDocument: vi.fn().mockRejectedValue(new Error("missing")) } as unknown as RepositoryGateway;
    const result = await prepareRepositorySwitch(gateway, { kind: "path", path: "/站点/乙" }, "content/old.md", () => true);
    expect(gateway.openRepository).toHaveBeenCalledWith("/站点/乙");
    expect(result?.restoreFailed).toBe(true);
    expect(result?.document).toBeNull();
  });
});
