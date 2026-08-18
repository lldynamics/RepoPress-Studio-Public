# RepoPress Studio performance profiling

Use synthetic Release benchmarks for deterministic complexity regressions and
Instruments traces for real SwiftUI update, CPU, hitch, and memory evidence.
Hosted-runner wall time remains trend-only because runner hardware is noisy.

## Fixed-hardware capture

Run a Release capture on the same Mac, macOS, and Xcode version before and after
a change:

```bash
bash script/capture_release_performance_trace.sh \
  --scenario typing \
  --duration 30s \
  --note "Type continuously in the 100,000-character Markdown fixture."
```

Supported scenarios are `launch`, `typing`, `rss`, `image-batch`, and
`ai-streaming`. Interactive scenarios require a reproduction note so a trace
cannot be mistaken for comparable evidence without describing the action.
The script builds the packaged Release app, records the Xcode `App Launch`
template for launch captures or the `SwiftUI` template for interactive captures,
and stores the `.trace` plus commit/toolchain/host metadata under
`.build/performance-traces/`.

When a time-limited App Launch recording ends the launched process, `xctrace`
may return status 54 after saving the trace. The script accepts that status only
after `xctrace export --toc` proves the trace is readable, and records the raw
status in `metadata.json`.

Use `--skip-build` only when `dist/PersonalSitePublisherMac.app` is already the
exact Release artifact being measured. Use `--template "Time Profiler"` or
`--template "Allocations"` for a narrower follow-up capture.

Compare the same interaction and fixture. Inspect SwiftUI Update Groups and long
view updates first, then correlate them with Time Profiler, Hangs and Hitches,
or Allocations. Do not convert results from different machines into blocking
wall-clock thresholds.

Apple references:

- https://developer.apple.com/documentation/xcode/understanding-and-improving-swiftui-performance
- https://developer.apple.com/documentation/xcode/xcode-command-line-tool-reference
