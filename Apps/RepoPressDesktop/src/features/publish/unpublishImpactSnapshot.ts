import type { ContentHealthSourceSnapshot } from "../../contracts/repository";

/** Equality is deliberately stricter than the findings: any source, membership,
 * raw-byte digest or omission change requires a new review. This is a point-in-time
 * reread, not a filesystem lock or an execution authorization. */
export function sameUnpublishImpactSources(before: ContentHealthSourceSnapshot, after: ContentHealthSourceSnapshot): boolean {
  const normalized = (snapshot: ContentHealthSourceSnapshot) => ({ ...snapshot,
    documents: [...snapshot.documents].sort((a, b) => a.relativePath < b.relativePath ? -1 : a.relativePath > b.relativePath ? 1 : 0),
  });
  return JSON.stringify(normalized(before)) === JSON.stringify(normalized(after));
}
