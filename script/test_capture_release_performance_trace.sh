#!/usr/bin/env bash
set -euo pipefail

# Keep byte-oriented assertions deterministic when the repository path contains
# non-ASCII characters and Bash renders shell-escaped command arguments.
export LC_ALL=C

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/script/capture_release_performance_trace.sh"

launch_output="$(bash "$SCRIPT" --dry-run --scenario launch --duration 12s)"
grep -Fq 'scenario=launch' <<<"$launch_output"
grep -Fq -- '--template App\ Launch' <<<"$launch_output"
grep -Fq -- '--time-limit 12s' <<<"$launch_output"
grep -Fq 'RepoPress Studio.app' <<<"$launch_output"

typing_output="$(
  bash "$SCRIPT" \
    --dry-run \
    --scenario typing \
    --duration 30s \
    --note 'Type continuously in the large Markdown fixture.'
)"
grep -Fq 'scenario=typing' <<<"$typing_output"
grep -Fq 'Type continuously in the large Markdown fixture.' <<<"$typing_output"
grep -Fq -- '--template SwiftUI' <<<"$typing_output"

scroll_output="$(
  bash "$SCRIPT" \
    --dry-run \
    --scenario markdown-scroll \
    --duration 20s \
    --document-length 1000 \
    --scroll-pattern ping-pong \
    --scroll-cycles 3 \
    --minimum-apply-samples 4 \
    --frame-budget-ms 12.5 \
    --hang-threshold-ms 200 \
    --note 'Continuously scroll the 100k Markdown fixture without moving the selection.'
)"
grep -Fq 'scenario=markdown-scroll' <<<"$scroll_output"
grep -Fq 'document_length=1000' <<<"$scroll_output"
grep -Fq 'scroll_pattern=ping-pong' <<<"$scroll_output"
grep -Fq 'scroll_cycles=3' <<<"$scroll_output"
grep -Fq 'scroll_start_delay_seconds=4' <<<"$scroll_output"
grep -Fq 'minimum_apply_samples=4' <<<"$scroll_output"
grep -Fq 'frame_budget_ms=12.5' <<<"$scroll_output"
grep -Fq 'hang_threshold_ms=200' <<<"$scroll_output"
grep -Fq 'Continuously scroll the 100k Markdown fixture without moving the selection.' <<<"$scroll_output"
grep -Fq -- '--template Time\ Profiler' <<<"$scroll_output"
grep -Fq 'HOME=' <<<"$scroll_output"
grep -Fq 'CFFIXED_USER_HOME=' <<<"$scroll_output"
grep -Fq 'TMPDIR=' <<<"$scroll_output"
grep -Fq 'PERSONAL_SITE_PUBLISHER_PERFORMANCE_PERSISTENCE_ROOT=' <<<"$scroll_output"
grep -Fq 'PERFORMANCE_FIXTURE=markdown-scroll' <<<"$scroll_output"
grep -Fq 'PERFORMANCE_FIXTURE_UTF16_LENGTH=1000' <<<"$scroll_output"
grep -Fq 'PERFORMANCE_AUTO_SCROLL=1' <<<"$scroll_output"
grep -Fq 'PERFORMANCE_AUTO_SCROLL_PATTERN=ping-pong' <<<"$scroll_output"
grep -Fq 'PERFORMANCE_AUTO_SCROLL_CYCLES=3' <<<"$scroll_output"
grep -Fq 'PERFORMANCE_AUTO_SCROLL_START_DELAY_SECONDS=4' <<<"$scroll_output"
grep -Fq 'REPOPRESS_TEXTKIT2_READ_ONLY_PRESENTATION=0' <<<"$scroll_output"
grep -Fq '/usr/bin/env -i' <<<"$scroll_output"
if grep -Fq 'PERSONAL_SITE_PUBLISHER_SCREENSHOT_' <<<"$scroll_output"; then
  echo "Markdown performance dry-run still depends on App Store screenshot automation" >&2
  exit 1
fi

manual_scroll_output="$(
  bash "$SCRIPT" \
    --dry-run \
    --scenario markdown-scroll \
    --interaction-driver manual \
    --duration 30s \
    --note 'Manually scroll the fixed 100k Markdown fixture with native input.'
)"
grep -Fq 'scenario=markdown-scroll' <<<"$manual_scroll_output"
grep -Fq 'interaction_driver=manual' <<<"$manual_scroll_output"
grep -Fq 'document_length=100000' <<<"$manual_scroll_output"
grep -Fq 'automatic_interaction=false' <<<"$manual_scroll_output"
grep -Fq 'manual_scroll_contract=native-operator-controlled' <<<"$manual_scroll_output"
grep -Fq 'physical_input_identified=false' <<<"$manual_scroll_output"
grep -Fq 'PERSONAL_SITE_PUBLISHER_PERFORMANCE_INTERACTION_DRIVER=manual' <<<"$manual_scroll_output"
if grep -Fq 'PERFORMANCE_AUTO_SCROLL' <<<"$manual_scroll_output"; then
  echo "manual scroll dry-run enabled PERFORMANCE_AUTO_SCROLL" >&2
  exit 1
fi
if grep -Fq 'scroll_pattern=' <<<"$manual_scroll_output"; then
  echo "manual scroll dry-run exposed a programmatic scroll pattern" >&2
  exit 1
fi

manual_rich_scroll_output="$(
  bash "$SCRIPT" \
    --dry-run \
    --scenario markdown-rich-scroll \
    --interaction-driver manual \
    --duration 30s \
    --minimum-apply-samples 6 \
    --frame-budget-ms 12.5 \
    --hang-threshold-ms 200 \
    --note 'Manually scroll the fixed 100k rich Markdown fixture with native input.'
)"
grep -Fq 'scenario=markdown-rich-scroll' <<<"$manual_rich_scroll_output"
grep -Fq 'interaction_driver=manual' <<<"$manual_rich_scroll_output"
grep -Fq 'document_length=100000' <<<"$manual_rich_scroll_output"
grep -Fq 'automatic_interaction=false' <<<"$manual_rich_scroll_output"
grep -Fq 'minimum_apply_samples=6' <<<"$manual_rich_scroll_output"
grep -Fq 'frame_budget_ms=12.5' <<<"$manual_rich_scroll_output"
grep -Fq 'hang_threshold_ms=200' <<<"$manual_rich_scroll_output"
grep -Fq 'contains_inline_images=true' <<<"$manual_rich_scroll_output"
grep -Fq 'contains_math_attachments=true' <<<"$manual_rich_scroll_output"
if grep -Fq 'PERFORMANCE_AUTO_SCROLL' <<<"$manual_rich_scroll_output"; then
  echo "manual rich scroll dry-run enabled PERFORMANCE_AUTO_SCROLL" >&2
  exit 1
fi

isolated_scroll_output="$(
  bash "$SCRIPT" \
    --dry-run \
    --scenario markdown-scroll \
    --duration 20s \
    --output-directory /private/tmp/repopress-textkit2-ui-map-capture-contract \
    --document-length 1000 \
    --note 'Verify CoreFoundation home isolation in the env-i launch.'
)"
isolated_launch_line="$(sed -n 's/^launch=//p' <<<"$isolated_scroll_output")"
isolated_home="$(sed -n 's/.*[[:space:]]HOME=\([^[:space:]]*\).*/\1/p' <<<"$isolated_launch_line")"
isolated_cf_home="$(sed -n 's/.*[[:space:]]CFFIXED_USER_HOME=\([^[:space:]]*\).*/\1/p' <<<"$isolated_launch_line")"
[[ -n "$isolated_home" && "$isolated_home" == "$isolated_cf_home" ]]

read_only_output="$(
  REPOPRESS_TEXTKIT2_READ_ONLY_PRESENTATION=1 \
    bash "$SCRIPT" \
      --dry-run \
      --scenario markdown-scroll \
      --duration 20s \
      --document-length 1000 \
      --note 'Opt in to the TextKit 2 read-only presentation trace.'
)"
grep -Fq 'REPOPRESS_TEXTKIT2_READ_ONLY_PRESENTATION=1' <<<"$read_only_output"

rich_scroll_output="$(
  bash "$SCRIPT" \
    --dry-run \
    --scenario markdown-rich-scroll \
    --duration 24s \
    --document-length 2000 \
    --scroll-pattern loop \
    --scroll-cycles 2 \
    --minimum-apply-samples 6 \
    --frame-budget-ms 11.25 \
    --hang-threshold-ms 175 \
    --note 'Scroll the rich Markdown fixture with inline images and math attachments.'
)"
grep -Fq 'scenario=markdown-rich-scroll' <<<"$rich_scroll_output"
grep -Fq 'document_length=2000' <<<"$rich_scroll_output"
grep -Fq 'scroll_pattern=loop' <<<"$rich_scroll_output"
grep -Fq 'scroll_cycles=2' <<<"$rich_scroll_output"
grep -Fq 'minimum_apply_samples=6' <<<"$rich_scroll_output"
grep -Fq 'frame_budget_ms=11.25' <<<"$rich_scroll_output"
grep -Fq 'hang_threshold_ms=175' <<<"$rich_scroll_output"
grep -Fq 'fixture_kind=markdown-rich-scroll' <<<"$rich_scroll_output"
grep -Fq 'source_document_fixture=markdown-rich-attachments' <<<"$rich_scroll_output"
grep -Fq 'contains_inline_images=true' <<<"$rich_scroll_output"
grep -Fq 'contains_math_attachments=true' <<<"$rich_scroll_output"
grep -Fq 'HOME=' <<<"$rich_scroll_output"
grep -Fq 'CFFIXED_USER_HOME=' <<<"$rich_scroll_output"
grep -Fq 'TMPDIR=' <<<"$rich_scroll_output"
grep -Fq 'PERFORMANCE_FIXTURE=markdown-rich-scroll' <<<"$rich_scroll_output"
grep -Fq 'PERFORMANCE_FIXTURE_UTF16_LENGTH=2000' <<<"$rich_scroll_output"
grep -Fq 'PERFORMANCE_AUTO_SCROLL=1' <<<"$rich_scroll_output"
grep -Fq 'PERFORMANCE_AUTO_SCROLL_PATTERN=loop' <<<"$rich_scroll_output"
grep -Fq 'PERFORMANCE_AUTO_SCROLL_CYCLES=2' <<<"$rich_scroll_output"
grep -Fq 'PERFORMANCE_AUTO_SCROLL_START_DELAY_SECONDS=4' <<<"$rich_scroll_output"
grep -Fq -- '--template Time\ Profiler' <<<"$rich_scroll_output"
grep -Fq -- '--attach \<capture-pid\>' <<<"$rich_scroll_output"

typing_output="$(
  bash "$SCRIPT" \
    --dry-run \
    --scenario markdown-typing \
    --duration 20s \
    --document-length 1000 \
    --typing-edits 12 \
    --typing-start-delay-seconds 3 \
    --typing-interval-ms 80 \
    --minimum-apply-samples 4 \
    --frame-budget-ms 12.5 \
    --hang-threshold-ms 200 \
    --note 'Run deterministic NSTextView edits; this is not IME composition.'
)"
grep -Fq 'scenario=markdown-typing' <<<"$typing_output"
grep -Fq 'document_length=1000' <<<"$typing_output"
grep -Fq 'typing_edits=12' <<<"$typing_output"
grep -Fq 'typing_start_delay_seconds=3' <<<"$typing_output"
grep -Fq 'typing_interval_ms=80' <<<"$typing_output"
grep -Fq 'typing_editing_settle_delay_seconds=0.5' <<<"$typing_output"
grep -Fq 'typing_analysis_settle_grace_ms=500' <<<"$typing_output"
grep -Fq 'minimum_apply_samples=4' <<<"$typing_output"
grep -Fq 'frame_budget_ms=12.5' <<<"$typing_output"
grep -Fq 'hang_threshold_ms=200' <<<"$typing_output"
grep -Fq 'Run deterministic NSTextView edits; this is not IME composition.' <<<"$typing_output"
grep -Fq -- '--template Time\ Profiler' <<<"$typing_output"
grep -Fq 'PERFORMANCE_FIXTURE=markdown-scroll' <<<"$typing_output"
grep -Fq 'CFFIXED_USER_HOME=' <<<"$typing_output"
grep -Fq 'PERFORMANCE_AUTO_TYPING=1' <<<"$typing_output"
grep -Fq 'PERFORMANCE_AUTO_TYPING_EDITS=12' <<<"$typing_output"
grep -Fq 'PERFORMANCE_AUTO_TYPING_INTERVAL_MILLISECONDS=80' <<<"$typing_output"
grep -Fq 'PERFORMANCE_AUTO_TYPING_START_DELAY_SECONDS=3' <<<"$typing_output"
grep -Fq 'PERFORMANCE_AUTO_TYPING_SETTLE_DELAY_SECONDS=0.5' <<<"$typing_output"
grep -Fq '/usr/bin/env -i' <<<"$typing_output"
grep -Fq -- '--attach \<capture-pid\>' <<<"$typing_output"
grep -Fq 'Run deterministic NSTextView edits; this is not IME composition.' <<<"$typing_output"

manual_typing_output="$(
  bash "$SCRIPT" \
    --dry-run \
    --scenario markdown-typing \
    --interaction-driver manual \
    --duration 45s \
    --minimum-apply-samples 1 \
    --note 'Use a native Chinese input method and commit candidate text.'
)"
grep -Fq 'scenario=markdown-typing' <<<"$manual_typing_output"
grep -Fq 'interaction_driver=manual' <<<"$manual_typing_output"
grep -Fq 'document_length=100000' <<<"$manual_typing_output"
grep -Fq 'automatic_interaction=false' <<<"$manual_typing_output"
grep -Fq 'manual_typing_contract=native-text-input-client' <<<"$manual_typing_output"
grep -Fq 'input_source_identified=false' <<<"$manual_typing_output"
grep -Fq 'ime_candidate_window_traceable=false' <<<"$manual_typing_output"
grep -Fq 'PERSONAL_SITE_PUBLISHER_PERFORMANCE_INTERACTION_DRIVER=manual' \
  <<<"$manual_typing_output"
if grep -Fq 'PERFORMANCE_AUTO_TYPING' <<<"$manual_typing_output"; then
  echo "manual typing dry-run enabled PERFORMANCE_AUTO_TYPING" >&2
  exit 1
fi
if grep -Fq 'typing_edits=' <<<"$manual_typing_output"; then
  echo "manual typing dry-run exposed programmatic typing controls" >&2
  exit 1
fi

grep -Fq '"programmaticEditing": True' "$ROOT_DIR/script/capture_release_performance_trace.sh"
grep -Fq '"imeComposition": False' "$ROOT_DIR/script/capture_release_performance_trace.sh"
grep -Fq '"programmaticEditing": is_typing and not is_manual' "$ROOT_DIR/script/analyze_markdown_scroll_trace.py"
grep -Fq '"imeComposition": None if not is_typing or is_manual else False' "$ROOT_DIR/script/analyze_markdown_scroll_trace.py"
grep -Fq 'DEFAULT_TYPING_SETTLE_GRACE_MILLISECONDS = 500.0' \
  "$ROOT_DIR/script/analyze_markdown_scroll_trace.py"
grep -Fq 'choices=("markdown-scroll", "markdown-rich-scroll", "markdown-typing")' \
  "$ROOT_DIR/script/analyze_markdown_scroll_trace.py"
grep -Fq 'upper_bound=interaction_analysis_end' \
  "$ROOT_DIR/script/analyze_markdown_scroll_trace.py"
grep -Fq 'ignoredLifecycleHangCount' \
  "$ROOT_DIR/script/analyze_markdown_scroll_trace.py"
python3 - "$ROOT_DIR/script/analyze_markdown_scroll_trace.py" <<'PY'
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("trace_analyzer", sys.argv[1])
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)

intervals = [(100, 200)]
assert module.containing_interval(intervals, 120, 180) == (100, 200)
assert module.containing_interval(intervals, 80, 180) is None
assert module.containing_interval(intervals, 120, 220) is None
PY

python3 - "$ROOT_DIR/script/analyze_markdown_scroll_trace.py" <<'PY'
import importlib.util
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path
from types import SimpleNamespace
import sys

spec = importlib.util.spec_from_file_location("trace_analyzer", sys.argv[1])
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)

APP = "PersonalSitePublisherMac"
APP_SUBSYSTEM = "com.jinfang.PersonalSitePublisherMac"
APPKIT_SUBSYSTEM = "com.apple.AppKit"
START = 1_000_000_000
END = 2_000_000_000


def write_table(path: Path, columns: list[str], rows: list[dict[str, str]]) -> None:
    root = ET.Element("trace-toc")
    schema = ET.SubElement(root, "schema")
    for column in columns:
        column_element = ET.SubElement(schema, "col")
        ET.SubElement(column_element, "mnemonic").text = column
    for values in rows:
        row = ET.SubElement(root, "row")
        for column in columns:
            ET.SubElement(row, "value").text = values.get(column, "")
    ET.ElementTree(root).write(path, encoding="utf-8", xml_declaration=True)


def signpost_rows(
    include_fallback: bool = False,
    include_deactivation: bool = False,
    inline_attachment_count: int = 0,
    manual: bool = False,
    native_projection: bool = False,
    native_attachment_count: int = 12,
    native_image_count: int = 4,
):
    rows = [] if manual else [
        {
            "name": "AutoScroll",
            "subsystem": APP_SUBSYSTEM,
            "event-type": "Begin",
            "time": str(START),
            "identifier": "auto",
            "message": "documentLength: 1000 pattern: ping-pong cycles: 1",
            "process": APP,
        },
        {
            "name": "AutoScroll",
            "subsystem": APP_SUBSYSTEM,
            "event-type": "End",
            "time": str(END),
            "identifier": "auto",
            "message": "completedCycles: 1",
            "process": APP,
        },
    ]
    if native_projection:
        rows.extend(
            [
                {
                    "name": "ReadOnlyPresentationShow",
                    "subsystem": APP_SUBSYSTEM,
                    "event-type": "Begin",
                    "time": str(START + 25_000_000),
                    "identifier": "presentation-show",
                    "message": "sourceUTF16Length: 100000, requestedAttachmentCount: 1",
                    "process": APP,
                },
                {
                    "name": "ReadOnlyPresentationShow",
                    "subsystem": APP_SUBSYSTEM,
                    "event-type": "End",
                    "time": str(START + 35_000_000),
                    "identifier": "presentation-show",
                    "message": (
                        "result: installed, reason: installed, cacheHit: 1, cacheStatus: hit, "
                        f"sourceUTF16Length: 100000, presentationUTF16Length: 60000, "
                        f"installedAttachmentCount: {native_attachment_count}"
                    ),
                    "process": APP,
                },
                {
                    "name": "ReadOnlyPresentationImageLoadsScheduled",
                    "subsystem": APP_SUBSYSTEM,
                    "event-type": "Event",
                    "time": str(START + 36_000_000),
                    "message": (
                        f"sourceUTF16Length: 100000, presentationUTF16Length: 60000, "
                        f"attachmentCount: {native_attachment_count}, "
                        f"imageLoadCount: {native_image_count}"
                    ),
                    "process": APP,
                },
            ]
        )
    for index in range(5):
        begin = START + 100_000_000 + index * 100_000_000
        if not native_projection:
            rows.extend(
                [
                    {
                        "name": "ApplyAttributes",
                        "subsystem": APP_SUBSYSTEM,
                        "event-type": "Begin",
                        "time": str(begin),
                        "identifier": f"apply-{index}",
                        "process": APP,
                    },
                    {
                        "name": "ApplyAttributes",
                        "subsystem": APP_SUBSYSTEM,
                        "event-type": "End",
                        "time": str(begin + 1_000_000),
                        "identifier": f"apply-{index}",
                        "message": "documentLength: 100000",
                        "process": APP,
                    },
                ]
            )
        rows.extend(
            [
                {
                    "name": "AutoScrollStep",
                    "subsystem": APP_SUBSYSTEM,
                    "event-type": "Begin",
                    "time": str(begin + 2_000_000),
                    "identifier": f"scroll-{index}",
                    "process": APP,
                },
                {
                    "name": "AutoScrollStep",
                    "subsystem": APP_SUBSYSTEM,
                    "event-type": "End",
                    "time": str(begin + 3_000_000),
                    "identifier": f"scroll-{index}",
                    "process": APP,
                },
            ]
        )
    for index in range(inline_attachment_count):
        begin = START + 150_000_000 + index * 100_000_000
        rows.extend(
            [
                {
                    "name": "ApplyInlineAttachmentOverlays",
                    "subsystem": APP_SUBSYSTEM,
                    "event-type": "Begin",
                    "time": str(begin),
                    "identifier": f"inline-{index}",
                    "process": APP,
                },
                {
                    "name": "ApplyInlineAttachmentOverlays",
                    "subsystem": APP_SUBSYSTEM,
                    "event-type": "End",
                    "time": str(begin + 1_000_000),
                    "identifier": f"inline-{index}",
                    "process": APP,
                },
            ]
        )
    if manual:
        rows = [row for row in rows if row["name"] != "AutoScrollStep"]
    if include_fallback:
        rows.append(
            {
                "name": "TreeSitterFallback",
                "subsystem": APP_SUBSYSTEM,
                "event-type": "Event",
                "time": str(START + 600_000_000),
                "message": (
                    "reason: tree-sitter-unavailable, rangeLocation: 12, "
                    "rangeLength: 5, count: 1"
                ),
                "process": APP,
            }
        )
    if include_deactivation:
        rows.extend(
            [
                {
                    "name": "Deactivation",
                    "subsystem": APPKIT_SUBSYSTEM,
                    "event-type": "Begin",
                    "time": str(START + 300_000_000),
                    "identifier": "deactivation",
                    "process": APP,
                },
                {
                    "name": "Deactivation",
                    "subsystem": APPKIT_SUBSYSTEM,
                    "event-type": "End",
                    "time": str(START + 800_000_000),
                    "identifier": "deactivation",
                    "process": APP,
                },
            ]
        )
    return rows


def analyze_fixture(
    root: Path,
    name: str,
    *,
    fallback=False,
    deactivation=False,
    scenario="markdown-scroll",
    inline_attachment_count=0,
    driver="programmatic",
    manual=False,
    native_projection=False,
    native_attachment_count=12,
    native_image_count=4,
):
    signposts = root / f"{name}-signposts.xml"
    samples = root / f"{name}-samples.xml"
    hangs = root / f"{name}-hangs.xml"
    write_table(
        signposts,
        ["name", "subsystem", "event-type", "time", "identifier", "message", "process", "thread"],
        signpost_rows(
            include_fallback=fallback,
            include_deactivation=deactivation,
            inline_attachment_count=inline_attachment_count,
            manual=manual,
            native_projection=native_projection,
            native_attachment_count=native_attachment_count,
            native_image_count=native_image_count,
        ),
    )
    write_table(
        samples,
        ["process", "thread", "thread-state", "time"],
        [{"process": APP, "thread-state": "Running", "time": str(START + 500_000_000)}],
    )
    hang_rows = []
    if deactivation:
        hang_rows.append(
            {
                "process": APP,
                "start": str(START + 400_000_000),
                "duration": "300000000",
                "hang-type": "Main thread",
            }
        )
    write_table(hangs, ["process", "thread", "start", "duration", "hang-type"], hang_rows)
    arguments = SimpleNamespace(
        scenario=scenario,
        signposts=signposts,
        time_samples=samples,
        hangs=hangs,
        minimum_apply_samples=5,
        frame_budget_ms=16.667,
        hang_threshold_ms=250.0,
        interaction_driver=driver,
    )
    return module.analyze(arguments)


with tempfile.TemporaryDirectory() as temporary_directory:
    root = Path(temporary_directory)
    no_fallback_report, interaction_valid, performance_passed = analyze_fixture(
        root, "no-fallback"
    )
    assert interaction_valid and performance_passed
    assert no_fallback_report["treeSitterFallbackEventCount"] == 0
    assert no_fallback_report["validation"]["noTreeSitterFallbacks"]

    fallback_report, interaction_valid, performance_passed = analyze_fixture(
        root, "fallback", fallback=True
    )
    assert interaction_valid and not performance_passed
    assert fallback_report["treeSitterFallbackEventCount"] == 1
    assert fallback_report["treeSitterFallback"]["latestReason"] == "tree-sitter-unavailable"
    assert fallback_report["treeSitterFallback"]["latestRange"] == {
        "location": 12,
        "length": 5,
    }
    assert fallback_report["treeSitterFallback"]["latestReportedCount"] == 1

    deactivation_report, interaction_valid, performance_passed = analyze_fixture(
        root, "deactivation", deactivation=True
    )
    assert interaction_valid and performance_passed
    assert deactivation_report["hangs"]["ignoredLifecycleHangCount"] == 1
    assert deactivation_report["hangs"]["blockingHangCount"] == 0

    rich_report, interaction_valid, performance_passed = analyze_fixture(
        root,
        "rich-attachments",
        scenario="markdown-rich-scroll",
        inline_attachment_count=5,
    )
    assert interaction_valid and performance_passed
    assert rich_report["inlineAttachmentOverlays"] == {
        "intervalCount": 5,
        "minimumSampleCount": 5,
        "sampleCountSufficient": True,
        "requiredByScenario": True,
    }

    missing_rich_report, interaction_valid, performance_passed = analyze_fixture(
        root,
        "missing-rich-attachments",
        scenario="markdown-rich-scroll",
        inline_attachment_count=4,
    )
    assert interaction_valid and not performance_passed
    assert not missing_rich_report["validation"][
        "inlineAttachmentSampleCountSufficient"
    ]

    native_rich_report, interaction_valid, performance_passed = analyze_fixture(
        root,
        "native-rich-attachments",
        scenario="markdown-rich-scroll",
        native_projection=True,
    )
    assert interaction_valid and performance_passed
    assert native_rich_report["readOnlyPresentation"] == {
        "observedDuringInteraction": True,
        "usesNativeRichPresentation": True,
        "showIntervalCount": 1,
        "installedShowCount": 1,
        "cacheHitShowCount": 1,
        "cacheStatuses": ["hit"],
        "showMedianMilliseconds": 10.0,
        "showMaximumMilliseconds": 10.0,
        "installedAttachmentCount": 12,
        "imageLoadEventCount": 1,
        "scheduledImageLoadCount": 4,
        "nativeRichAttachmentValidation": True,
    }
    assert not native_rich_report["applyAttributes"]["requiredByRenderPath"]
    assert not native_rich_report["inlineAttachmentOverlays"]["requiredByScenario"]
    assert native_rich_report["automaticScroll"]["stepP95Milliseconds"] == 1.0

    native_missing_math_report, interaction_valid, performance_passed = analyze_fixture(
        root,
        "native-rich-missing-math",
        scenario="markdown-rich-scroll",
        native_projection=True,
        native_attachment_count=4,
        native_image_count=4,
    )
    assert not interaction_valid and not performance_passed
    assert not native_missing_math_report["validation"][
        "nativeRichAttachmentValidation"
    ]

    manual_report, interaction_valid, performance_passed = analyze_fixture(
        root,
        "manual-scroll",
        driver="manual",
        manual=True,
    )
    assert interaction_valid
    assert not performance_passed
    assert manual_report["interactionDriver"] == "manual"
    assert manual_report["manualReviewRequired"]
    assert manual_report["metricGatePassed"]
    assert not manual_report["performancePassed"]
    assert manual_report["manualScroll"] == {
        "analysisWindowDurationMilliseconds": 401.0,
        "automaticInteractionDetected": False,
        "manualReviewRequired": True,
        "operatorEvidenceRequired": True,
        "physicalInputIdentified": False,
    }
    assert manual_report["manualTyping"] is None

    manual_typing_report, interaction_valid, performance_passed = analyze_fixture(
        root,
        "manual-typing",
        scenario="markdown-typing",
        driver="manual",
        manual=True,
    )
    assert interaction_valid
    assert not performance_passed
    assert manual_typing_report["interactionDriver"] == "manual"
    assert manual_typing_report["manualReviewRequired"]
    assert manual_typing_report["metricGatePassed"]
    assert not manual_typing_report["performancePassed"]
    assert manual_typing_report["manualScroll"] is None
    assert manual_typing_report["automaticTyping"]["programmaticEditing"] is False
    assert manual_typing_report["automaticTyping"]["imeComposition"] is None
    assert manual_typing_report["manualTyping"] == {
        "analysisWindowDurationMilliseconds": 401.0,
        "automaticInteractionDetected": False,
        "manualReviewRequired": True,
        "operatorEvidenceRequired": True,
        "inputSourceIdentified": False,
        "imeCandidateWindowTraceable": False,
    }

    manual_rich_report, interaction_valid, performance_passed = analyze_fixture(
        root,
        "manual-rich-scroll",
        scenario="markdown-rich-scroll",
        driver="manual",
        manual=True,
        inline_attachment_count=5,
    )
    assert interaction_valid and not performance_passed
    assert manual_rich_report["metricGatePassed"]
    assert manual_rich_report["validation"]["manualReviewRequired"]

    manual_missing_rich_report, interaction_valid, performance_passed = analyze_fixture(
        root,
        "manual-missing-rich-scroll",
        scenario="markdown-rich-scroll",
        driver="manual",
        manual=True,
        inline_attachment_count=4,
    )
    assert interaction_valid and not performance_passed
    assert not manual_missing_rich_report["metricGatePassed"]
PY

if bash "$SCRIPT" --dry-run --scenario typing >/dev/null 2>&1; then
  echo "interactive scenario accepted a missing reproduction note" >&2
  exit 1
fi
if bash "$SCRIPT" --dry-run --scenario markdown-typing >/dev/null 2>&1; then
  echo "markdown-typing accepted a missing reproduction note" >&2
  exit 1
fi
typing_default_output="$(
  bash "$SCRIPT" \
    --dry-run \
    --scenario markdown-typing \
    --note 'Use the typing scenario defaults.'
)"
grep -Fq 'minimum_apply_samples=1' <<<"$typing_default_output"
if bash "$SCRIPT" --dry-run --scenario unsupported --note test >/dev/null 2>&1; then
  echo "unsupported scenario was accepted" >&2
  exit 1
fi
if bash "$SCRIPT" --dry-run --duration 0s >/dev/null 2>&1; then
  echo "zero duration was accepted" >&2
  exit 1
fi
if bash "$SCRIPT" --dry-run --document-length 1000 >/dev/null 2>&1; then
  echo "non-markdown scenario accepted --document-length" >&2
  exit 1
fi
if bash "$SCRIPT" --dry-run --scenario markdown-scroll --document-length 999 --note test \
  >/dev/null 2>&1; then
  echo "markdown-scroll accepted an undersized document" >&2
  exit 1
fi
if bash "$SCRIPT" --dry-run --scenario markdown-scroll --scroll-pattern zigzag --note test \
  >/dev/null 2>&1; then
  echo "markdown-scroll accepted an unsupported scroll pattern" >&2
  exit 1
fi
if bash "$SCRIPT" --dry-run --scenario markdown-scroll --scroll-cycles 0 --note test \
  >/dev/null 2>&1; then
  echo "markdown-scroll accepted zero scroll cycles" >&2
  exit 1
fi
if bash "$SCRIPT" --dry-run --scenario markdown-scroll --scroll-cycles 33 --note test \
  >/dev/null 2>&1; then
  echo "markdown-scroll accepted more than 32 scroll cycles" >&2
  exit 1
fi
if bash "$SCRIPT" --dry-run --scenario markdown-scroll --minimum-apply-samples 0 --note test \
  >/dev/null 2>&1; then
  echo "markdown-scroll accepted zero minimum samples" >&2
  exit 1
fi
if bash "$SCRIPT" --dry-run --scenario markdown-scroll --frame-budget-ms 0 --note test \
  >/dev/null 2>&1; then
  echo "markdown-scroll accepted a zero frame budget" >&2
  exit 1
fi
if bash "$SCRIPT" --dry-run --scenario markdown-scroll --hang-threshold-ms -1 --note test \
  >/dev/null 2>&1; then
  echo "markdown-scroll accepted a negative hang threshold" >&2
  exit 1
fi
if bash "$SCRIPT" --dry-run --scenario markdown-scroll --typing-edits 12 --note test \
  >/dev/null 2>&1; then
  echo "markdown-scroll accepted a typing option" >&2
  exit 1
fi
if bash "$SCRIPT" --dry-run --scenario markdown-rich-scroll --typing-edits 12 --note test \
  >/dev/null 2>&1; then
  echo "markdown-rich-scroll accepted a typing option" >&2
  exit 1
fi
if bash "$SCRIPT" --dry-run --scenario markdown-typing --interaction-driver manual \
  --typing-edits 12 --note test >/dev/null 2>&1; then
  echo "manual markdown-typing accepted programmatic typing controls" >&2
  exit 1
fi
if bash "$SCRIPT" --dry-run --scenario markdown-scroll --interaction-driver manual \
  --document-length 100001 --note test >/dev/null 2>&1; then
  echo "manual scroll accepted a non-fixed document length" >&2
  exit 1
fi
if bash "$SCRIPT" --dry-run --scenario markdown-scroll --interaction-driver manual \
  --scroll-pattern loop --note test >/dev/null 2>&1; then
  echo "manual scroll accepted a programmatic scroll pattern" >&2
  exit 1
fi
if bash "$SCRIPT" --dry-run --scenario markdown-typing --scroll-pattern loop --note test \
  >/dev/null 2>&1; then
  echo "markdown-typing accepted a scroll option" >&2
  exit 1
fi
if bash "$SCRIPT" --dry-run --scenario markdown-typing --typing-edits 5 --note test \
  >/dev/null 2>&1; then
  echo "markdown-typing accepted fewer than six edits" >&2
  exit 1
fi
if bash "$SCRIPT" --dry-run --scenario markdown-typing --typing-interval-ms 15 --note test \
  >/dev/null 2>&1; then
  echo "markdown-typing accepted an interval shorter than 16 milliseconds" >&2
  exit 1
fi
if bash "$SCRIPT" --dry-run --scenario markdown-typing --typing-start-delay-seconds 0 --note test \
  >/dev/null 2>&1; then
  echo "markdown-typing accepted a zero start delay" >&2
  exit 1
fi
if bash "$SCRIPT" --dry-run --scenario launch --scroll-pattern loop >/dev/null 2>&1; then
  echo "launch accepted a markdown scroll option" >&2
  exit 1
fi

grep -Fq '"schemaVersion": 4' "$SCRIPT"
grep -Fq 'capture_trace_provenance.py' "$SCRIPT"
grep -Fq 'workingTreeDirty' "$SCRIPT"
grep -Fq 'workingTreeStateHash' "$SCRIPT"
grep -Fq 'TRACE_INTERACTION_DRIVER' "$SCRIPT"
grep -Fq 'os.environ["TRACE_INTERACTION_DRIVER"] if is_markdown_scenario' "$SCRIPT"
grep -Fq '"interactionDriver": (' "$SCRIPT"
grep -Fq '"automaticInteraction": os.environ["TRACE_INTERACTION_DRIVER"] == "programmatic"' "$SCRIPT"
grep -Fq 'manualInteractionContract' "$SCRIPT"
grep -Fq 'physicalInputIdentified' "$SCRIPT"
grep -Fq 'fixedDocumentUTF16Length' "$SCRIPT"
grep -Fq 'manualReviewRequired' "$SCRIPT"

python3 - "$ROOT_DIR/script/capture_trace_provenance.py" <<'PY'
import importlib.util
import subprocess
import sys
import tempfile
from pathlib import Path

spec = importlib.util.spec_from_file_location("trace_provenance", sys.argv[1])
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)


def git(root: Path, *arguments: str) -> None:
    subprocess.run(["git", "-C", str(root), *arguments], check=True, stdout=subprocess.PIPE)


with tempfile.TemporaryDirectory() as temporary_directory:
    root = Path(temporary_directory)
    git(root, "init", "-q")
    git(root, "config", "user.email", "trace-test@example.invalid")
    git(root, "config", "user.name", "Trace Test")
    tracked = root / "tracked.txt"
    tracked.write_text("baseline\n", encoding="utf-8")
    (root / ".gitignore").write_text("/Fixture.app/\n", encoding="utf-8")
    git(root, "add", "tracked.txt", ".gitignore")
    git(root, "commit", "-qm", "baseline")

    bundle = root / "Fixture.app"
    binary = bundle / "Contents" / "MacOS" / "Fixture"
    binary.parent.mkdir(parents=True)
    binary.write_bytes(b"fixture-binary-v1")

    clean = module.build_payload(root, bundle, binary)
    clean_again = module.build_payload(root, bundle, binary)
    assert clean["workingTreeDirty"] is False
    assert clean["reproducibleCleanCommit"] is True
    assert clean["workingTreeStateHash"] == clean_again["workingTreeStateHash"]
    assert clean["appBinarySHA256"].startswith("sha256:")
    assert clean["appBundleSHA256"].startswith("sha256:")

    tracked.write_text("working-tree-change\n", encoding="utf-8")
    tracked_only = module.build_payload(root, bundle, binary)
    assert tracked_only["workingTreeDirty"] is True
    assert tracked_only["reproducibleCleanCommit"] is False
    assert tracked_only["workingTreeStateHash"] != clean["workingTreeStateHash"]
    tracked.write_text("baseline\n", encoding="utf-8")

    tracked.write_text("staged-change\n", encoding="utf-8")
    git(root, "add", "tracked.txt")
    staged_only = module.build_payload(root, bundle, binary)
    assert staged_only["workingTreeDirty"] is True
    assert staged_only["workingTreeStateHash"] != clean["workingTreeStateHash"]
    git(root, "reset", "-q", "--hard", "HEAD")

    untracked = root / "untracked-secret-looking-name.txt"
    untracked.write_text("untracked-content\n", encoding="utf-8")
    untracked_only = module.build_payload(root, bundle, binary)
    assert untracked_only["workingTreeDirty"] is True
    assert untracked_only["workingTreeStateHash"] != clean["workingTreeStateHash"]
    serialized = str(untracked_only)
    assert "untracked-content" not in serialized
    assert "untracked-secret-looking-name.txt" not in serialized
    untracked.unlink()

    clean_after = module.build_payload(root, bundle, binary)
    assert clean_after["workingTreeDirty"] is False
    assert clean_after["workingTreeStateHash"] == clean["workingTreeStateHash"]
PY

echo "release performance trace contract: passed"
