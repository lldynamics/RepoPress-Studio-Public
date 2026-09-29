# RepoPress Studio performance profiling

> Type: current operational guide. See the [documentation source rules](README.md).

Use synthetic Release benchmarks for deterministic complexity regressions and
Instruments traces for real AppKit/TextKit, CPU, hang, hitch, and memory
evidence. Hosted-runner wall time remains trend-only because runner hardware is
noisy. A trace is comparable only when the Mac, macOS, Xcode, configuration, and
fixture are held constant. The authoritative capture interface is
[`script/capture_release_performance_trace.sh`](../script/capture_release_performance_trace.sh),
trace analysis is [`script/analyze_markdown_scroll_trace.py`](../script/analyze_markdown_scroll_trace.py),
and the independent Release benchmark lane is
[`script/run_release_performance_benchmarks.py`](../script/run_release_performance_benchmarks.py).
The progressive benchmark contract is configured in
[`script/quality_baselines.json`](../script/quality_baselines.json); this
document does not duplicate its numeric baseline values.

## Bounded background and editor work

The current implementation bounds these workloads without changing persisted
article content or search ranking:

- The composer computes outline entries only while the outline panel is visible
  or an explicit caller requests them. Diagnostics continue independently;
  opening or pinning the outline immediately schedules a current full analysis.
- Selection-only editor updates within the visible area retain the document-height
  cache. Offscreen selections, text edits, wrapping-width changes and folded front
  matter still invalidate geometry. Mounted AppKit interaction
  tests cover the caret and manual-scroll contract; native IME acceptance remains
  a separate capture path below.
- [`WorkbenchThumbnailCache`](../Sources/PersonalSitePublisherMac/Support/WorkbenchThumbnailView.swift)
  bounds utility-priority decodes and retained decoded bytes, keeps least-recently
  used entries within its budget, and shares requests between subscribers.
  Cancelling one subscriber preserves the others; a newly visible subscriber
  retries if the previous decode is already cancelling. The limits are owned by
  that implementation. A large grid may show placeholders while work is queued;
  original image files are not changed.
- RSS header searches can stop during database-lock waits and SQLite execution.
  The cancellation handler is scoped to read queries and removed before the
  connection is reused. Write transactions retain their existing semantics.
- Draft updates reconcile deleted image-report state only when draft membership
  changes. Background refreshes reuse their completed input signature for cache
  lookup; explicit reads and final installation still check external image files.
- Creating or renaming a knowledge folder preserves an already-current semantic
  vector snapshot. This exception applies only to folder-label writes: earlier
  document, permission, archival, revision or vector changes still invalidate it.
  Search remains exact and continues to enforce current permissions.
- The composer requests scroll progress without querying a top-visible source
  line, because its session persistence consumes only progress. Other consumers
  retain source-line reporting by default, and source-line scroll application
  remains available. The reporting setting updates on an already-mounted editor
  without resetting coalescing or restoration state.
- The task inspector retains one provenance classification for its current exact
  draft identity, tags and Markdown body. Repeated presentation reads and unrelated
  metadata edits reuse it; body edits (including equal-length replacements), tag
  edits and draft switches recompute it. The cache belongs to the inspector's view
  lifetime and does not publish its internal updates or retain a whole workspace.
- Core localization resolves the packaged resource bundle and each explicit
  language bundle lazily once per process. It continues to look up strings and
  format values for each request; explicit locale calls can alternate languages.
  App display language now follows macOS's per-app language setting; automatic
  formatting locale behavior remains unchanged.
- Automatic custom slash snippets first check for an exact shortcut on the
  current line. Partial or unknown commands no longer scan the whole document
  for code ranges on each keystroke. A complete match still checks code ranges
  and uses the existing completion candidate, preserving fenced-code exclusion,
  UTF-16 replacement ranges and placeholder selection. This reduces work in
  the automatic snippet path; it does not establish native IME or overall
  editor latency improvements.
- Stale palette paragraph metrics are reset by a synchronous MainActor range
  walk. This avoids capturing AppKit objects in a nested Objective-C enumeration
  block that fails Swift 6 Release isolation diagnostics, while preserving
  metrics owned by attachments and limiting writes to the requested range.
- During native marked-text composition, repeated preedit changes coalesce
  document-height invalidation and defer syntax parsing, layout-attribute
  application, contextual-anchor geometry, automatic snippets, and statistics
  updates. Temporary selection changes avoid extra TextKit layout queries.
  Source-only documents also reuse the live editor string for the body after
  validating the edit, avoiding a whole-body mutable copy on each preedit.
  The committed text still refreshes those states, while the live body channel
  continues to receive each edit. The simulated input-client regression checks
  cache and commit behavior; only a manual `markdown-typing` trace with an
  observed input source can establish native IME latency and caret stability.
- Incremental editor statistics have a total UTF-16 processing budget covering
  word-boundary probes, old/new word contexts and edit-fragment scans. Long
  unbroken tokens that exceed it retain the last exact displayed statistics
  and schedule the existing delayed background full scan. Subsequent edits
  cannot reuse that stale incremental base; generation and document mapping
  checks still reject an obsolete full result.
- Knowledge navigation shares one document snapshot for folder, unfiled and
  smart-collection counts. Document mutations invalidate it; selection and
  hover changes reuse it. Saved-collection counts retain only the current rule
  set, and rule changes refresh those counts without retaining prior sets.
  Time-sensitive smart collections also refresh when the calendar day changes.
- External draft scans use cumulative content, directory-depth and visited-entry
  budgets in addition to the existing per-file and file-count limits. They
  enumerate lazily and reject the whole result on a budget failure. Cancellation
  propagates to the background scanner and is checked between entries and file
  reads. Individual descriptor-based reads are bounded by the remaining budget.
- Repository image filtering propagates cancellation to its background task.
  Scope filtering, text filtering and bounded groups of sort comparisons check
  for cancellation; the existing inventory revision and task identity checks
  still protect installation of the result.

Current and whole-document replacement plans run off the main actor in a cancellable task. Installation checks the draft, body revision and text, query, replacement, options, and selection scope again. A stale plan cannot replace newer text. The current replacement remains undoable; replace-all retains its preview. This changes where planning runs, without asserting a measured latency improvement.

Repository content events still perform an authoritative scan. Skipping it would
leave the visible Git change list stale, so path-only import is not a substitute
for repository-state refresh.

These are workload and correctness contracts, not a measured speedup claim.
Collect comparable Release traces before assigning a latency or frame-rate gain.

On 2026-09-29, an isolated `swiftc -O` probe of the unchanged complete syntax
range planner measured ordinary insertions at the start, middle and end of
synthetic documents with 1, 1,000 and 10,000 fenced blocks. For 10,000 blocks,
the medians of seven 100-call batch averages ranged from 0.040 to 0.046 ms per
plan. This does not measure parsing, TextKit or UI latency. It did not justify
replacing the current interval representation as part of the bounded-work
changes; the linear interval update remains a candidate for future traces.

For the `@Observable` migration, a child view that receives an already owned
reference stores it as `let`; `@State` is reserved for an observable reference
created and owned by that view. `AIBatchMaintenancePanel` uses the store-owned
maintenance instance. The opt-in
[`ObservationOwnershipPerformanceTests`](../Tests/PersonalSitePublisherMacTests/ObservationOwnershipPerformanceTests.swift)
mounts equivalent `@State` and `let` probes against externally owned
observable models, changes each model 200 times, verifies all 201 body evaluations, and prints
wall times in alternating order. Run with
`RUN_OBSERVATION_OWNERSHIP_BENCHMARK=1 swift test --disable-sandbox --filter ObservationOwnershipPerformanceTests`.
Those timings compare the ownership pattern; an app latency claim still needs
matching Release traces of the panel.

On 2026-09-27, the opt-in SwiftPM Debug test used the actual `@Observable`
macro with an offscreen `NSHostingView`. Six samples per variant in ABBA order
gave medians of 10.68 ms for `@State` and 10.58 ms for `let`, with every sample
rendering 201 bodies. A repeat gave 11.20 ms and 11.50 ms respectively. This
small view probe did not show a meaningful speed difference and does not
measure the full panel.

On 2026-09-27, a local `swiftc -O` SwiftUI/AppKit probe using an equivalent
`ObservationRegistrar` model ran six samples per variant in ABBA order. Each
sample rendered all 200 updates (201 body evaluations including the first
render). Median elapsed time was 21.70 ms with `@State` and 21.81 ms with
`let`. This separate Release proxy also showed no meaningful speed difference;
the change establishes correct ownership of the store reference.

## Deterministic scheduling tests

The interaction debounce windows used by the editor and search coordinators are
named in [`DebounceIntervals`](../Sources/PublishingCoreSupport/DebounceIntervals.swift).
Production scheduling defaults to `ContinuousClock`; tests inject
[`ManualClock`](../Tests/PublishingTestSupport/ManualClock.swift), wait until a
sleep is registered, and advance across its deadline. This checks that work
does not run early, cancelled work does not publish, and the latest edit wins
without relying on a longer wall-clock sleep in the test. The preview page
readiness check uses the same injected clock for retry pauses and its wait
deadline; each call starts its own deadline.

These tests establish ordering and cancellation. The mounted editor still
requires AppKit layout assertions, and a virtual clock alone does not measure
typing latency or native input behavior.

## Markdown scenarios

The Markdown migration has three fixture contracts and two interaction drivers:

- `markdown-scroll`: a 1,000–1,000,000 UTF-16 plain Markdown fixture with
  forward, ping-pong, or loop scrolling.
- `markdown-rich-scroll`: the same viewport exercise with inline images and
  math attachments; this is the required rich-content scrolling evidence.
- `markdown-typing`: deterministic `NSTextView.insertText:replacementRange`
  edits against a long fixture, including Chinese and Emoji UTF-16 boundaries.

All Markdown scenarios use the `programmatic` driver by default. Pass
`--interaction-driver manual` to use the same isolated fixture with a native,
operator-controlled interaction window. Manual scrolling is deliberately a
separate evidence path: the app is launched without
`PERSONAL_SITE_PUBLISHER_PERFORMANCE_AUTO_SCROLL`, and the capture cannot infer
whether the operator used a mouse, trackpad, keyboard, or another native input
source. It therefore makes no claim about a physical trackpad.

Programmatic `markdown-typing` is not native IME composition. Its report records
`programmaticEditing: true` and `imeComposition: false`. Manual
`markdown-typing` disables automatic edits and routes operator keystrokes
through the native text input system. The trace still cannot identify the input
source or prove that a candidate window appeared, so operator review remains
required.

For every Markdown trace, the analyzer requires the configured sample,
frame-budget, hang, overlay, and fallback conditions. Query the current
accepted defaults and parameter names before capture or analysis:

```bash
bash script/capture_release_performance_trace.sh --help
python3 script/analyze_markdown_scroll_trace.py --help
```

The current analyzer contract includes:

- `ApplyAttributes` P95 no greater than the configured frame budget;
- enough samples for the selected scenario;
- for `markdown-rich-scroll`, at least the same number of
  `ApplyInlineAttachmentDrawings` samples (or `ApplyInlineAttachmentOverlays`
  for older traces), so a fixture that never exercised attachment application
  cannot pass as rich-content evidence; when both names exist, the current
  drawing samples take precedence rather than adding the two counts;
- attachment application P95 no greater than the same frame budget, including
  drawing work deferred beyond the synchronous `ApplyAttributes` interval;
- no blocking hang at or above the configured threshold; and
- zero `TreeSitterFallback` signpost events.

The last condition is intentional: a green frame-time result must not hide an
unexpected fallback to the legacy parser. The generated `analysis.json`
contains `treeSitterFallbackEventCount` and, when the signpost payload is
parseable, each event's `reason`, UTF-16 `range`, and cumulative `count`.
Every Markdown report also contains `interactionDriver`. A manual report keeps
the measured constraints in `metricGatePassed`, sets
`manualReviewRequired: true`, and intentionally leaves `performancePassed: false`;
this prevents a trace with no machine-verifiable scroll event from being
presented as an automated green result.

Phase timings retain current `ApplyBlockMarkerDrawings` and
`ApplyInlineAttachmentDrawings` names alongside their legacy overlay names.
For compatibility, `inlineAttachmentOverlays` remains the JSON attachment
evidence field; `inlineAttachmentEvidence.phaseName` identifies which
instrumentation supplied the samples. Reanalysis after an analyzer correction must retain the
original report and identify the corrected analyzer separately. It does not
change the recorded application or prove asynchronous image-decode completion.

Current drawing phases use a bounded settling window after programmatic
scrolling, as typing already does. A drawing that starts within that window
contributes its full paired duration even if it finishes after the boundary;
an unfinished inline drawing within the window fails the gate. Manual captures
retain their observed window. Synchronous phases and legacy overlays retain
their existing interval boundaries, and the report identifies the drawing
window separately.

## Fixed-hardware Release capture

Run the same scenario before and after a change on the same Mac, macOS, and
Xcode version. Markdown captures must use a packaged Release capture build:

```bash
bash script/capture_release_performance_trace.sh \
  --scenario markdown-scroll \
  --duration 30s \
  --document-length 100000 \
  --scroll-pattern ping-pong \
  --scroll-cycles 4 \
  --note "Scroll the 100,000-character plain Markdown fixture."

bash script/capture_release_performance_trace.sh \
  --scenario markdown-rich-scroll \
  --duration 30s \
  --document-length 100000 \
  --scroll-pattern loop \
  --scroll-cycles 4 \
  --note "Scroll the rich Markdown fixture with inline images and math attachments."

bash script/capture_release_performance_trace.sh \
  --scenario markdown-typing \
  --duration 30s \
  --document-length 100000 \
  --typing-edits 24 \
  --note "Run deterministic NSTextView edits; this is not IME composition."
```

### Manual native interaction capture

Use this path when a real window and operator-controlled scrolling are needed:

```bash
bash script/capture_release_performance_trace.sh \
  --scenario markdown-scroll \
  --interaction-driver manual \
  --duration 30s \
  --note "Manually scroll the fixed 100,000-character Markdown fixture."

bash script/capture_release_performance_trace.sh \
  --scenario markdown-rich-scroll \
  --interaction-driver manual \
  --duration 30s \
  --minimum-apply-samples 5 \
  --note "Manually scroll the fixed rich Markdown fixture with image and math attachments."

bash script/capture_release_performance_trace.sh \
  --scenario markdown-typing \
  --interaction-driver manual \
  --duration 45s \
  --minimum-apply-samples 1 \
  --note "Use a native Chinese input method, show candidates, commit text, and continue typing."
```

Manual captures always use a fixture minimum of 100,000 UTF-16 units and reject
other length parameters. Whole fixture blocks and front matter can make the
actual editor document longer; the analysis records that observed length.
The script opens the isolated Release capture app, starts an
attached `xctrace` recording, and leaves the editor window focused for the
operator. During a scroll recording, keep the Markdown editor focused and
scroll continuously without typing. During a typing recording, use the intended
native input method and commit candidate text without scrolling. Do not switch
applications. `--dry-run` is the auditable check that the launch environment
contains `interactionDriver=manual` and no matching `PERFORMANCE_AUTO_SCROLL`
or `PERFORMANCE_AUTO_TYPING` setting.

Manual analysis still enforces the minimum `ApplyAttributes` samples, the
60-FPS P95 budget, zero blocking hangs, zero `TreeSitterFallback` events, and
for `markdown-rich-scroll` at least the same number of inline-attachment
application samples, with the drawing/legacy selection described above. The
absence of an `AutoScroll` or `AutoTyping` signpost is
expected for this driver; it is not treated as a missing automatic interaction.
Because the current trace schema has no machine-verifiable operator event,
inspect the trace and confirm the interaction yourself before using it as UI
evidence.

The script stores the `.trace`, exported signposts, `analysis.json`, and
commit/toolchain/host metadata under `.build/performance-traces/`. Use
`--skip-build` only when `dist/RepoPress Studio.app` is already the
exact Release artifact being measured. Use `--template "Time Profiler"` or
`--template "Allocations"` for a narrower follow-up capture.

When a time-limited recording ends the launched process, `xctrace` may return
status 54 after saving the trace. The script accepts that status only after
`xctrace export --toc` proves the trace is readable, and records the raw status
in `metadata.json`.

For the separate deterministic Release benchmark lane, use the driver and
configuration declared by the quality baseline:

```bash
python3 script/run_release_performance_benchmarks.py --configuration release
```

It writes raw samples and host provenance. Its structural/complexity checks are
blocking; wall time remains trend evidence according to
`script/quality_baselines.json`. Query available benchmark parameters with:

```bash
python3 script/run_release_performance_benchmarks.py --help
```

Module build timing is a separate, non-mutating measurement. Query its plan
with [`script/benchmark_swift_module_builds.py`](../script/benchmark_swift_module_builds.py):

```bash
python3 script/benchmark_swift_module_builds.py --plan
python3 script/benchmark_swift_module_builds.py --help
python3 script/benchmark_swift_module_builds.py \
  --configuration release \
  --repetitions 3 \
  --scenario cold \
  --scenario warm \
  --scenario incremental
```

Its host wall time is trend evidence only; it does not define a release gate.

## Complexity boundary

For a stable, already parsed document, an ordinary local edit and the
viewport-padded attribute application are bounded by the changed region and
visible viewport (effectively O(1) with respect to total document length). This
does not make every operation O(1). Initial parsing, a missing syntax-tree
cache, invalid edit ranges, and an unresolved code fence that reaches EOF may
still scan a document-sized range. Large replacements also deliberately use a
conservative path. Report these cases separately instead of using the stable
typing result to claim universal O(1) behavior.

Compare the same interaction and fixture. Inspect `ApplyAttributes`,
`ApplyRenderingAttributes`, `ApplyInlineAttachmentOverlays`, Time Profiler,
Hangs and Hitches, or Allocations together. Do not convert results from
different machines into blocking wall-clock thresholds.

Apple references:

- https://developer.apple.com/documentation/xcode/understanding-and-improving-swiftui-performance
- https://developer.apple.com/documentation/xcode/xcode-command-line-tool-reference
