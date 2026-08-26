# RepoPress Studio performance profiling

Use synthetic Release benchmarks for deterministic complexity regressions and
Instruments traces for real AppKit/TextKit, CPU, hang, hitch, and memory
evidence. Hosted-runner wall time remains trend-only because runner hardware is
noisy. A trace is comparable only when the Mac, macOS, Xcode, configuration, and
fixture are held constant.

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

For every Markdown trace, the analyzer requires:

- `ApplyAttributes` P95 no greater than the configured frame budget (default
  `16.667 ms`, the 60 FPS frame budget);
- enough samples (default 5 for scroll scenarios and 1 for typing);
- for `markdown-rich-scroll`, at least the same number of
  `ApplyInlineAttachmentOverlays` samples, so a fixture that never exercised
  native image/math overlays cannot pass as rich-content evidence;
- no blocking hang of at least `250 ms` (configurable); and
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

Manual captures always load the fixed 100,000 UTF-16 fixture and reject other
document lengths. The script opens the isolated Release capture app, starts an
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
overlay samples. The absence of an `AutoScroll` or `AutoTyping` signpost is
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
