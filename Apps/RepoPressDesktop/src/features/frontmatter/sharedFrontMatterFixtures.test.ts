import { describe, expect, it } from "vitest";
import manifest from "../../../../../Shared/RepoPressCoreContracts/contracts/fixtures/v1/manifest.json";
import { parseFrontMatter, updateFrontMatterField } from "./frontMatter";

interface RenderFixture {
  id: string;
  capability: string;
  validity: string;
  input: { document: { syntax: string; title: string; formattedDate: string; tags: string[]; categories: string[] } };
  expected: { ok: boolean; value?: { text: string } };
}

const fixtures = import.meta.glob<RenderFixture>(
  "../../../../../Shared/RepoPressCoreContracts/contracts/fixtures/v1/front-matter-document/*.json",
  { eager: true, import: "default" },
);
const yamlCases = manifest.cases
  .filter((entry) => entry.path.startsWith("front-matter-document/front-yaml-"))
  .map((entry) => fixtures[`../../../../../Shared/RepoPressCoreContracts/contracts/fixtures/v1/${entry.path}`]);

// These are producer/reader compatibility checks, not a claim that Linux
// implements the shared renderer, nested TOML tables, or every contract domain.
describe("shared YAML producer / Linux reader compatibility", () => {
  it("consumes every valid YAML case in the shared manifest", () => {
    expect(yamlCases.map((fixture) => fixture.id)).toEqual([
      "front-yaml-empty-fields-render", "front-yaml-full-render", "front-yaml-markdown-trim",
      "front-yaml-minimal-render", "front-yaml-unicode-render",
    ]);
  });

  it.each(yamlCases)("reads and preserves $id through the real metadata editor", (fixture) => {
    expect(fixture.capability).toBe("front-matter-document");
    expect(fixture.validity).toBe("valid");
    expect(fixture.expected.ok).toBe(true);
    const source = fixture.expected.value!.text;
    const document = fixture.input.document;
    const parsed = parseFrontMatter(source);
    expect(parsed?.issue).toBeNull();
    expect(parsed?.style).toBe("yaml");
    expect(parsed?.values).toMatchObject({
      title: document.title, date: document.formattedDate,
      tags: document.tags, categories: document.categories,
    });
    expect(updateFrontMatterField(source, "title", document.title)).toBe(source);
  });
});
