import { describe, expect, it } from "vitest";
import { LatestPreferenceSelection } from "./latestPreferenceSelection";

describe("LatestPreferenceSelection", () => {
  it("accepts a return to the persisted value while an earlier choice is pending", () => {
    const selection = new LatestPreferenceSelection<"basic" | "professional">();
    const professional = selection.request("professional", "basic");
    const basic = selection.request("basic", "basic");

    expect(professional).toBe(1);
    expect(basic).toBe(2);
    expect(selection.current("basic")).toBe("basic");
  });

  it("only lets the newest request clear the optimistic value", () => {
    const selection = new LatestPreferenceSelection<"basic" | "professional">();
    const professional = selection.request("professional", "basic") as number;
    const basic = selection.request("basic", "basic") as number;

    expect(selection.settle(professional)).toBe(false);
    expect(selection.current("professional")).toBe("basic");
    expect(selection.settle(basic)).toBe(true);
    expect(selection.current("professional")).toBe("professional");
  });
});
