import { describe, expect, it } from "vitest";
import { ExitActivityGate } from "./exitActivity";

describe("ExitActivityGate", () => {
  it("tracks pending work through success, rejection, and synchronous exceptions", async () => {
    const gate = new ExitActivityGate();
    let resolveWork!: (value: string) => void;
    const pending = gate.run(() => new Promise<string>((resolve) => { resolveWork = resolve; }));
    expect(gate.busy).toBe(true);
    resolveWork("done");
    await expect(pending).resolves.toBe("done");
    expect(gate.busy).toBe(false);

    await expect(gate.run(() => Promise.reject(new Error("failed")))).rejects.toThrow("failed");
    expect(gate.busy).toBe(false);

    const synchronousError = new Error("sync failed");
    await expect(gate.run(() => { throw synchronousError; })).rejects.toBe(synchronousError);
    expect(gate.busy).toBe(false);
  });

  it("keeps busy until all concurrent tasks settle", async () => {
    const gate = new ExitActivityGate();
    let resolveFirst!: () => void;
    let resolveSecond!: () => void;
    const first = gate.run(() => new Promise<void>((resolve) => { resolveFirst = resolve; }));
    const second = gate.run(() => new Promise<void>((resolve) => { resolveSecond = resolve; }));
    expect(gate.busy).toBe(true);
    resolveFirst();
    await first;
    expect(gate.busy).toBe(true);
    resolveSecond();
    await second;
    expect(gate.busy).toBe(false);
  });

  it("refuses to freeze while work is pending and blocks new work while frozen", async () => {
    const gate = new ExitActivityGate();
    let resolveWork!: () => void;
    const pending = gate.run(() => new Promise<void>((resolve) => { resolveWork = resolve; }));
    expect(() => gate.freeze()).toThrowError(expect.objectContaining({ code: "exit_busy" }));
    resolveWork();
    await pending;

    const release = gate.freeze();
    expect(gate.frozen).toBe(true);
    await expect(gate.run(async () => undefined)).rejects.toMatchObject({ code: "exit_in_progress" });
    release();
    expect(gate.frozen).toBe(false);
    await expect(gate.run(async () => "resumed")).resolves.toBe("resumed");
  });

  it("makes release idempotent and prevents stale releases from releasing a newer lease", () => {
    const gate = new ExitActivityGate();
    const staleRelease = gate.freeze();
    staleRelease();
    const currentRelease = gate.freeze();
    staleRelease();
    expect(gate.frozen).toBe(true);
    currentRelease();
    currentRelease();
    expect(gate.frozen).toBe(false);
    expect(() => gate.freeze()).not.toThrow();
  });
});
