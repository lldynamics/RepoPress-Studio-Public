# RepoPress shared M1 contract rules

This document defines the semantics that JSON Schema alone cannot express.
The schemas in `contracts/schemas/v1/` are the machine-readable shape; this
document is part of the same versioned contract.

## Version and boundaries

M1 is the first shared, language-neutral contract revision.  Its schemas are
JSON Schema Draft 2020-12 and use these URNs:

| capability | schema `$id` |
| --- | --- |
| fixture case | `urn:repopress:contracts:v1:fixture-case` |
| fixture manifest | `urn:repopress:contracts:v1:fixture-manifest` |
| repository endpoint | `urn:repopress:contracts:v1:repository-endpoint` |
| front-matter document | `urn:repopress:contracts:v1:front-matter-document` |
| publish conflict diff | `urn:repopress:contracts:v1:publish-conflict-diff` |

M1 describes deterministic values and rendering only.  It does not define an
App, SwiftUI/AppKit/UIKit screens, platform bridges, credentials or tokens,
authentication, network transport, `ArticleDraft`/`SiteProfile` persistence,
database migrations, or deployment.  A product may adapt these values at its
boundary, but must not treat a contract fixture as proof of an online service.

## File and JSON normalization

Every contract, fixture, and manifest JSON file is:

1. encoded as UTF-8 without a BOM;
2. terminated with LF (`\n`) only, with exactly one LF at EOF;
3. indented by two spaces;
4. serialized with `ensure_ascii=false` and `sort_keys=true`, where object keys
   are ordered by Unicode code point; and
5. free of duplicate keys and non-finite JSON numbers.

The canonical writer emits one final LF and no additional blank line.  JSON
object key order is therefore a reproducibility rule, not a semantic ordering
rule.  Rendered front matter has its own field order below.  Strings are
compared and emitted as supplied: no reader or writer may silently apply NFC,
NFD, case folding, width folding, or any other Unicode normalization.  An
implementation that wants normalized search keys must expose that as a
separate, explicit operation.

The case envelope has exactly these fields in the canonical JSON representation:
`id`, `capability`, `validity`, `description`, `input`, `expected`.  The only
capabilities are `repository-endpoint`, `front-matter-document`, and
`publish-conflict-diff`; `validity` is `valid` or `invalid`.

Optional values are omitted, not represented as `null`.  In particular,
`slug`, `draftFlag`, `summaryField`, `summary`, `coverField`, and `coverPath`
inside a front-matter document must be omitted when absent; an explicit null is
`contract.invalid_input`.  The one intentional nullable value is
`queryItems[].value`: `null` means a valueless URL query item and emits a bare
key (for example `?ref`), while a string emits `name=value`.  Empty strings and
empty arrays are values, not omission.

## Repository endpoint

The endpoint input envelope is `operation`, `baseURL`, optional `path`, and
optional `queryItems`.  `operation` is `validate` or `build-url`.

`validate` trims leading and trailing whitespace/newline characters from
`baseURL`, then requires HTTPS (case-insensitive scheme), a non-empty host, and
no user info, password, query, or fragment.  The resulting `baseURL` preserves
its self-hosted path (for example `/api/v3`) and is returned as the `value` of
the successful result.

`build-url` applies the same base URL checks, trims `/` characters at the join
boundary only, preserves the base path, and joins the optional request `path`
without introducing duplicate slashes.  An already percent-encoded path
segment such as `docs%2Findex.md` is not decoded or re-encoded into a literal
slash.  Query items use standard URL percent encoding in input order; a null
item value is a bare key.  The successful result is
`{"absoluteURL":"..."}`.  An omitted or slash-only path therefore returns the
validated base URL (including its base path).

## Front-matter document

The input envelope is `operation` (`render` or `markdown-document`) and a
`document` object.  Required document fields, in semantic order, are:
`syntax`, `title`, `formattedDate`, `authors`, `tags`, `categories`,
`taxonomyLayout`, `writesCoverInExtraTable`, and `bodyMarkdown`.  Optional
fields, in their render order, are `slug`, `draftFlag`, `summaryField`,
`summary`, `coverField`, and `coverPath`.  The arrays retain their input order;
empty collections are omitted from rendered output.

YAML output uses `---` fences.  Its field order is `title`, `date`, `slug`,
`tags`, `categories`, `authors`, `draft`, summary field, and cover field, then
the closing fence.  TOML output uses `+++` fences.  Its field order is
`title`, `date`, `slug`, `draft`, summary field, `authors`, direct cover (when
used), taxonomies, `[extra]`/`og_preview_img` (when used), then the closing
fence.  TOML dates are emitted as supplied and unquoted; YAML dates are quoted.
`taxonomyLayout` selects an inline `taxonomies = { ... }` table or a
`[taxonomies]` table.  `writesCoverInExtraTable` moves a TOML cover to
`[extra]` as `og_preview_img`.

All quoted scalars escape backslash, double quote, LF, CR, and tab in that
order.  Rendering does not normalize Unicode or reorder arrays.  For
`markdown-document`, the body is trimmed with the implementation's ordinary
whitespace/newline trimming semantics, joined to the front matter with one
blank line, and ends with exactly one LF.  `render` returns only the fenced
front matter (no body separator).

## Publish conflict diff

The input has exactly two strings: `remote` and `local`.  Each is split using
the platform-neutral equivalent of Swift `CharacterSet.newlines`.  This is a
character-set split, not a CRLF tokenization: CR and LF are each separators, so
`a\r\nb` produces `a`, an empty line, and `b`.  Separators are not included in
line `text`, and a trailing separator preserves a trailing empty line.  An
empty input still contains one empty line.

When `remoteLineCount * localLineCount <= 250000`, the strategy is `lcs` and
the longest-common-subsequence table is used.  On a mismatch, compare the
remaining-table cells; if the remote-side cell is greater than or equal to the
local-side cell, emit the remote line first.  This `>=` is the required stable
remote-first tie-break.  Equal lines emit one `same` line.  The markers are
` ` (same), `-` (remote), and `+` (local), and output line IDs are contiguous
zero-based integers.

When the product is greater than 250000 (strictly greater; exactly 250000 is
still LCS), use `coarse`.  Emit every remote line as `remote` followed by every
local line as `local`, with no attempted matching.  The result value is
`{"strategy":"lcs"|"coarse","lines":[...]}`.

## Errors

`expected` is either `{ "ok": true, "value": ... }` or
`{ "ok": false, "errorCode": "..." }`; the two forms are mutually exclusive
and have no extra fields.  Error codes are stable machine identifiers, never
localized user-facing text.  M1 reserves at least:

- `contract.invalid_input` — missing/unknown fields, wrong operation, explicit
  null where omission is required, or another envelope/type violation;
- `repository_endpoint.invalid_url` — an endpoint URL fails the HTTPS/host,
  credentials, query, or fragment checks;
- `front_matter_document.invalid_document` — a document cannot satisfy the
  rendering contract; and
- `publish_conflict_diff.invalid_input` — the remote/local diff input is not
  two strings.

Readers should preserve unknown future error codes rather than translating or
guessing a message.  A failed case must not include a partial `value`.
