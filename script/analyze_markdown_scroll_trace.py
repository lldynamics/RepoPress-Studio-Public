#!/usr/bin/env python3
"""Summarize an isolated Markdown scroll, rich scroll, or typing export.

Programmatic scroll/typing traces carry an application signpost interval. A
manual interaction trace deliberately does not: its analysis window is bounded
by the app's exported signposts and its result is marked for operator review.
"""

from __future__ import annotations

import argparse
import json
import math
import re
import statistics
import xml.etree.ElementTree as ET
from pathlib import Path
from typing import Any


APP_PROCESS_NAME = "PersonalSitePublisherMac"
APP_SUBSYSTEM = "com.jinfang.PersonalSitePublisherMac"
APPKIT_SUBSYSTEM = "com.apple.AppKit"
DEFAULT_MINIMUM_APPLY_SAMPLES = 5
DEFAULT_TYPING_MINIMUM_APPLY_SAMPLES = 1
DEFAULT_FRAME_BUDGET_MILLISECONDS = 16.667
DEFAULT_HANG_THRESHOLD_MILLISECONDS = 250.0
DEFAULT_TYPING_SETTLE_GRACE_MILLISECONDS = 500.0
TREE_SITTER_FALLBACK_EVENT_NAME = "TreeSitterFallback"
MANUAL_SCENARIOS = ("markdown-scroll", "markdown-rich-scroll", "markdown-typing")


class TraceTable:
    def __init__(self, path: Path) -> None:
        self.root = ET.parse(path).getroot()
        self.ids = {
            element.attrib["id"]: element
            for element in self.root.iter()
            if "id" in element.attrib
        }
        schema = self.root.find(".//schema")
        self.columns = (
            [column.findtext("mnemonic", default="") for column in schema.findall("col")]
            if schema is not None
            else []
        )

    def resolved(self, element: ET.Element) -> ET.Element:
        reference = element.attrib.get("ref")
        return self.ids.get(reference, element) if reference else element

    def formatted(self, element: ET.Element) -> str:
        resolved = self.resolved(element)
        return resolved.attrib.get("fmt", resolved.text or "")

    def integer(self, element: ET.Element) -> int | None:
        resolved = self.resolved(element)
        try:
            return int((resolved.text or "").strip())
        except ValueError:
            return None

    def rows(self) -> list[dict[str, tuple[str, int | None]]]:
        parsed: list[dict[str, tuple[str, int | None]]] = []
        for row in self.root.findall(".//row"):
            values = list(row)
            parsed.append(
                {
                    column: (self.formatted(value), self.integer(value))
                    for column, value in zip(self.columns, values)
                }
            )
        return parsed


def text(row: dict[str, tuple[str, int | None]], key: str) -> str:
    return row.get(key, ("", None))[0]


def integer(row: dict[str, tuple[str, int | None]], key: str) -> int | None:
    return row.get(key, ("", None))[1]


def belongs_to_app(row: dict[str, tuple[str, int | None]]) -> bool:
    return APP_PROCESS_NAME in text(row, "process") or APP_PROCESS_NAME in text(row, "thread")


def percentile(values: list[float], fraction: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    index = max(0, math.ceil(len(ordered) * fraction) - 1)
    return ordered[index]


def positive_integer(value: str) -> int:
    try:
        parsed = int(value)
    except ValueError as error:
        raise argparse.ArgumentTypeError("must be an integer") from error
    if parsed < 1 or parsed > 10_000:
        raise argparse.ArgumentTypeError("must be between 1 and 10000")
    return parsed


def positive_float(value: str) -> float:
    try:
        parsed = float(value)
    except ValueError as error:
        raise argparse.ArgumentTypeError("must be a number") from error
    if not math.isfinite(parsed) or parsed <= 0:
        raise argparse.ArgumentTypeError("must be a finite number greater than 0")
    return parsed


def message_field(message: str, key: str) -> str | None:
    match = re.search(rf"{re.escape(key)}:\s*([^,\s]+)", message)
    return match.group(1) if match else None


def message_integer_field(message: str, key: str) -> int | None:
    value = message_field(message, key)
    if value is None:
        return None
    try:
        return int(value)
    except ValueError:
        return None


def fallback_reason(message: str) -> str | None:
    match = re.search(r"reason:\s*(.*?)(?:,\s*rangeLocation:|$)", message)
    if match is None:
        return None
    reason = match.group(1).strip()
    return reason or None


def tree_sitter_fallback_events(
    rows: list[dict[str, tuple[str, int | None]]],
) -> list[dict[str, Any]]:
    events: list[dict[str, Any]] = []
    for row in rows:
        if not belongs_to_app(row) or text(row, "name") != TREE_SITTER_FALLBACK_EVENT_NAME:
            continue
        message = text(row, "message")
        location = message_integer_field(message, "rangeLocation")
        length = message_integer_field(message, "rangeLength")
        reported_count = message_integer_field(message, "count")
        event: dict[str, Any] = {
            "reason": fallback_reason(message),
            "range": (
                {"location": location, "length": length}
                if location is not None and length is not None
                else None
            ),
            "reportedCount": reported_count,
        }
        timestamp = integer(row, "time")
        if timestamp is not None:
            event["timeNanoseconds"] = timestamp
        events.append(event)
    return events


def interval_durations(
    rows: list[dict[str, tuple[str, int | None]]],
    name: str,
    lower_bound: int | None = None,
    upper_bound: int | None = None,
    allowed_subsystems: tuple[str, ...] = ("", APP_SUBSYSTEM),
) -> list[tuple[int, int]]:
    starts: dict[str, int] = {}
    intervals: list[tuple[int, int]] = []
    for row in rows:
        if not belongs_to_app(row) or text(row, "name") != name:
            continue
        if text(row, "subsystem") not in allowed_subsystems:
            continue
        timestamp = integer(row, "time")
        identifier = text(row, "identifier")
        if timestamp is None or not identifier:
            continue
        event_type = text(row, "event-type")
        if event_type == "Begin":
            starts[identifier] = timestamp
        elif event_type == "End" and identifier in starts:
            start = starts.pop(identifier)
            if lower_bound is not None and start < lower_bound:
                continue
            if upper_bound is not None and timestamp > upper_bound:
                continue
            intervals.append((start, timestamp))
    return intervals


def completed_interval_records(
    rows: list[dict[str, tuple[str, int | None]]],
    name: str,
    lower_bound: int | None = None,
    upper_bound: int | None = None,
    allowed_subsystems: tuple[str, ...] = ("", APP_SUBSYSTEM),
) -> list[dict[str, Any]]:
    """Return paired interval timestamps together with their begin/end messages."""
    starts: dict[str, tuple[int, str]] = {}
    records: list[dict[str, Any]] = []
    for row in rows:
        if not belongs_to_app(row) or text(row, "name") != name:
            continue
        if text(row, "subsystem") not in allowed_subsystems:
            continue
        timestamp = integer(row, "time")
        identifier = text(row, "identifier")
        if timestamp is None or not identifier:
            continue
        event_type = text(row, "event-type")
        if event_type == "Begin":
            starts[identifier] = (timestamp, text(row, "message"))
        elif event_type == "End" and identifier in starts:
            start, begin_message = starts.pop(identifier)
            if lower_bound is not None and start < lower_bound:
                continue
            if upper_bound is not None and timestamp > upper_bound:
                continue
            records.append(
                {
                    "start": start,
                    "end": timestamp,
                    "beginMessage": begin_message,
                    "endMessage": text(row, "message"),
                }
            )
    return records


def containing_interval(
    intervals: list[tuple[int, int]],
    start: int,
    end: int,
) -> tuple[int, int] | None:
    """Return the lifecycle interval that fully contains a sampled hang.

    Partial overlap stays eligible for the performance gate: only a hang fully
    contained by AppKit's application-deactivation animation is classified as
    capture-environment noise.
    """
    return next(
        (
            (interval_start, interval_end)
            for interval_start, interval_end in intervals
            if interval_start <= start and end <= interval_end
        ),
        None,
    )


def milliseconds(nanoseconds: int) -> float:
    return nanoseconds / 1_000_000


def app_trace_time_bounds(
    rows: list[dict[str, tuple[str, int | None]]],
) -> tuple[int, int] | None:
    timestamps = [
        timestamp
        for row in rows
        if belongs_to_app(row)
        and (timestamp := integer(row, "time")) is not None
    ]
    return (min(timestamps), max(timestamps)) if timestamps else None


def document_length_from_signposts(
    rows: list[dict[str, tuple[str, int | None]]],
) -> int | None:
    for row in rows:
        if not belongs_to_app(row):
            continue
        match = re.search(r"documentLength:\s+([0-9,]+)", text(row, "message"))
        if match:
            return int(match.group(1).replace(",", ""))
    return None


def analyze(arguments: argparse.Namespace) -> tuple[dict[str, Any], bool, bool]:
    signposts = TraceTable(arguments.signposts).rows()
    samples = TraceTable(arguments.time_samples).rows()
    hangs = TraceTable(arguments.hangs).rows()
    fallback_events = tree_sitter_fallback_events(signposts)
    fallback_event_count = len(fallback_events)
    scenario = getattr(arguments, "scenario", "markdown-scroll")
    interaction_driver = getattr(arguments, "interaction_driver", "programmatic")
    is_typing = scenario == "markdown-typing"
    is_rich_scroll = scenario == "markdown-rich-scroll"
    is_manual = interaction_driver == "manual"
    if is_manual and scenario not in MANUAL_SCENARIOS:
        raise ValueError("manual interaction driver requires a Markdown scenario")
    interaction_name = "AutoTyping" if is_typing else "AutoScroll"
    step_name = "AutoTypingStep" if is_typing else "AutoScrollStep"
    configured_minimum_apply_samples = getattr(arguments, "minimum_apply_samples", None)
    minimum_apply_samples = (
        configured_minimum_apply_samples
        if configured_minimum_apply_samples is not None
        else (
            DEFAULT_TYPING_MINIMUM_APPLY_SAMPLES
            if is_typing
            else DEFAULT_MINIMUM_APPLY_SAMPLES
        )
    )
    frame_budget_milliseconds = getattr(
        arguments, "frame_budget_ms", DEFAULT_FRAME_BUDGET_MILLISECONDS
    )
    hang_threshold_milliseconds = getattr(
        arguments, "hang_threshold_ms", DEFAULT_HANG_THRESHOLD_MILLISECONDS
    )

    auto_intervals = interval_durations(signposts, interaction_name)
    auto_start: int | None = None
    auto_end: int | None = None
    if auto_intervals:
        auto_start, auto_end = max(auto_intervals, key=lambda interval: interval[1] - interval[0])
    manual_trace_bounds = app_trace_time_bounds(signposts) if is_manual else None
    interaction_start = manual_trace_bounds[0] if is_manual and manual_trace_bounds else auto_start
    interaction_end = manual_trace_bounds[1] if is_manual and manual_trace_bounds else auto_end
    interaction_analysis_end = (
        auto_end + int(DEFAULT_TYPING_SETTLE_GRACE_MILLISECONDS * 1_000_000)
        if is_typing and auto_end is not None
        else interaction_end
    )

    document_utf16_length: int | None = None
    scroll_pattern: str | None = None
    requested_cycle_count: int | None = None
    requested_edit_count: int | None = None
    if auto_start is not None:
        for row in signposts:
            if (
                belongs_to_app(row)
                and text(row, "name") == interaction_name
                and text(row, "event-type") == "Begin"
                and integer(row, "time") == auto_start
            ):
                message = text(row, "message")
                match = re.search(r"documentLength:\s+([0-9,]+)", message)
                if match:
                    document_utf16_length = int(match.group(1).replace(",", ""))
                if is_typing:
                    edits = message_field(message, "requestedEdits")
                    if edits is not None and edits.isdigit():
                        requested_edit_count = int(edits)
                else:
                    scroll_pattern = message_field(message, "pattern")
                    cycles = message_field(message, "cycles")
                    if cycles is not None and cycles.isdigit():
                        requested_cycle_count = int(cycles)
                break
    if document_utf16_length is None and is_manual:
        document_utf16_length = document_length_from_signposts(signposts)

    completed_cycle_count: int | None = None
    completed_edit_count: int | None = None
    if auto_end is not None:
        for row in signposts:
            if (
                belongs_to_app(row)
                and text(row, "name") == interaction_name
                and text(row, "event-type") == "End"
                and integer(row, "time") == auto_end
            ):
                if is_typing:
                    completed = message_field(text(row, "message"), "completedEdits")
                    if completed is not None and completed.isdigit():
                        completed_edit_count = int(completed)
                else:
                    completed = message_field(text(row, "message"), "completedCycles")
                    if completed is not None and completed.isdigit():
                        completed_cycle_count = int(completed)
                break

    step_rows: list[dict[str, tuple[str, int | None]]] = []
    if interaction_start is not None and interaction_end is not None:
        step_rows = [
            row
            for row in signposts
            if belongs_to_app(row)
            and text(row, "name") == step_name
            and (timestamp := integer(row, "time")) is not None
            and interaction_start <= timestamp <= interaction_end
        ]

    typing_step_intervals = (
        interval_durations(
            signposts,
            step_name,
            lower_bound=interaction_start,
            upper_bound=interaction_end,
        )
        if is_typing
        else []
    )
    scroll_step_intervals = (
        interval_durations(
            signposts,
            step_name,
            lower_bound=auto_start,
            upper_bound=auto_end,
        )
        if not is_typing
        else []
    )
    has_typing_step_intervals = bool(typing_step_intervals)
    has_scroll_step_intervals = bool(scroll_step_intervals)
    step_events = (
        len(typing_step_intervals)
        if has_typing_step_intervals
        else (
            len(scroll_step_intervals)
            if has_scroll_step_intervals
            else len(step_rows)
        )
    )

    unicode_boundary_sample_counts = {"chinese": 0, "emoji": 0}
    if is_typing and auto_start is not None and auto_end is not None:
        unicode_rows = (
            [row for row in step_rows if text(row, "event-type") == "Begin"]
            if has_typing_step_intervals
            else step_rows
        )
        for row in unicode_rows:
            unicode_class = message_field(text(row, "message"), "unicode")
            if unicode_class in unicode_boundary_sample_counts:
                unicode_boundary_sample_counts[unicode_class] += 1

    typing_step_durations = [
        milliseconds(end - start) for start, end in typing_step_intervals
    ]
    typing_step_p95_milliseconds = percentile(typing_step_durations, 0.95)
    typing_step_p95_within_frame_budget = (
        not is_typing
        or is_manual
        or (
            has_typing_step_intervals
            and typing_step_p95_milliseconds is not None
            and typing_step_p95_milliseconds <= frame_budget_milliseconds
        )
    )
    scroll_step_durations = [
        milliseconds(end - start) for start, end in scroll_step_intervals
    ]
    scroll_step_p95_milliseconds = percentile(scroll_step_durations, 0.95)
    scroll_step_p95_within_frame_budget = (
        not has_scroll_step_intervals
        or (
            scroll_step_p95_milliseconds is not None
            and scroll_step_p95_milliseconds <= frame_budget_milliseconds
        )
    )

    read_only_show_records = completed_interval_records(
        signposts,
        "ReadOnlyPresentationShow",
        lower_bound=auto_start,
        upper_bound=auto_end,
    )
    installed_read_only_shows = [
        record
        for record in read_only_show_records
        if message_field(record["endMessage"], "result") == "installed"
    ]
    cached_read_only_shows = [
        record
        for record in installed_read_only_shows
        if message_field(record["endMessage"], "cacheHit") in ("1", "true")
    ]
    read_only_cache_statuses = [
        status
        for record in installed_read_only_shows
        if (status := message_field(record["endMessage"], "cacheStatus"))
        is not None
    ]
    read_only_show_durations = [
        milliseconds(record["end"] - record["start"])
        for record in read_only_show_records
    ]
    installed_attachment_counts = [
        count
        for record in installed_read_only_shows
        if (count := message_integer_field(
            record["endMessage"], "installedAttachmentCount"
        )) is not None
    ]
    read_only_image_events = [
        row
        for row in signposts
        if belongs_to_app(row)
        and text(row, "name") == "ReadOnlyPresentationImageLoadsScheduled"
        and (timestamp := integer(row, "time")) is not None
        and auto_start is not None
        and auto_end is not None
        and auto_start <= timestamp <= auto_end
    ]
    scheduled_image_load_counts = [
        count
        for row in read_only_image_events
        if (count := message_integer_field(text(row, "message"), "imageLoadCount"))
        is not None
    ]
    read_only_presentation_observed = bool(read_only_show_records)
    maximum_installed_attachment_count = max(installed_attachment_counts, default=0)
    maximum_scheduled_image_load_count = max(scheduled_image_load_counts, default=0)
    native_rich_attachment_validation = (
        bool(installed_read_only_shows)
        and maximum_installed_attachment_count > 0
        and maximum_scheduled_image_load_count > 0
        and maximum_installed_attachment_count > maximum_scheduled_image_load_count
    )
    uses_native_rich_presentation = is_rich_scroll and read_only_presentation_observed

    apply_intervals = interval_durations(
        signposts,
        "ApplyAttributes",
        lower_bound=interaction_start,
        upper_bound=interaction_analysis_end,
    )
    apply_durations = [milliseconds(end - start) for start, end in apply_intervals]
    phase_names = (
        "ApplyRenderingAttributes",
        "ApplyMarkerAttributes",
        "ApplyBlockMarkerOverlays",
        "ApplyInlineAttachmentOverlays",
        "ApplyEditorOverlays",
    )
    phase_metrics: dict[str, dict[str, Any]] = {}
    for phase_name in phase_names:
        phase_intervals = interval_durations(
            signposts,
            phase_name,
            lower_bound=interaction_start,
            upper_bound=interaction_analysis_end,
        )
        phase_durations = [milliseconds(end - start) for start, end in phase_intervals]
        phase_metrics[phase_name] = {
            "intervalCount": len(phase_durations),
            "medianMilliseconds": (
                round(statistics.median(phase_durations), 3) if phase_durations else None
            ),
            "p95Milliseconds": (
                round(percentile(phase_durations, 0.95) or 0, 3) if phase_durations else None
            ),
            "maximumMilliseconds": (
                round(max(phase_durations), 3) if phase_durations else None
            ),
        }
    inline_attachment_sample_count = phase_metrics[
        "ApplyInlineAttachmentOverlays"
    ]["intervalCount"]
    minimum_inline_attachment_samples = (
        0 if uses_native_rich_presentation else minimum_apply_samples
    ) if is_rich_scroll else 0
    inline_attachment_sample_count_sufficient = (
        not is_rich_scroll
        or (
            native_rich_attachment_validation
            if uses_native_rich_presentation
            else inline_attachment_sample_count >= minimum_inline_attachment_samples
        )
    )

    cpu_samples = 0
    if interaction_start is not None and interaction_analysis_end is not None:
        cpu_samples = sum(
            1
            for row in samples
            if belongs_to_app(row)
            and text(row, "thread-state") == "Running"
            and (timestamp := integer(row, "time")) is not None
            and interaction_start <= timestamp <= interaction_analysis_end
        )

    application_deactivation_intervals = interval_durations(
        signposts,
        "Deactivation",
        lower_bound=interaction_start,
        upper_bound=interaction_analysis_end,
        allowed_subsystems=("", APPKIT_SUBSYSTEM),
    )
    overlapping_hangs: list[dict[str, Any]] = []
    if interaction_start is not None and interaction_analysis_end is not None:
        for row in hangs:
            if not belongs_to_app(row):
                continue
            start = integer(row, "start")
            duration = integer(row, "duration")
            if (
                start is None
                or duration is None
                or start + duration < interaction_start
                or start > interaction_analysis_end
            ):
                continue
            hang_end = start + duration
            deactivation_interval = containing_interval(
                application_deactivation_intervals,
                start,
                hang_end,
            )
            hang = {
                "type": text(row, "hang-type"),
                "startMilliseconds": round(milliseconds(start), 3),
                "durationMilliseconds": round(milliseconds(duration), 3),
            }
            if deactivation_interval is not None:
                hang["ignoredReason"] = "application-deactivation"
            overlapping_hangs.append(hang)

    blocking_hangs = [
        hang
        for hang in overlapping_hangs
        if "ignoredReason" not in hang
        and hang["durationMilliseconds"] >= hang_threshold_milliseconds
    ]
    ignored_lifecycle_hangs = [
        hang for hang in overlapping_hangs if hang.get("ignoredReason") == "application-deactivation"
    ]
    apply_sample_count = len(apply_durations)
    apply_sample_count_sufficient = (
        True
        if uses_native_rich_presentation
        else apply_sample_count >= minimum_apply_samples
    )
    apply_p95_milliseconds = percentile(apply_durations, 0.95)
    p95_within_frame_budget = (
        True
        if uses_native_rich_presentation
        else (
            apply_p95_milliseconds is not None
            and apply_p95_milliseconds <= frame_budget_milliseconds
        )
    )
    no_blocking_hangs = not blocking_hangs
    no_tree_sitter_fallbacks = fallback_event_count == 0
    automatic_interaction_signpost_count = sum(
        1
        for row in signposts
        if belongs_to_app(row) and text(row, "name") == interaction_name
    )
    no_automatic_interaction_signposts = automatic_interaction_signpost_count == 0
    typing_completion_valid = (
        is_manual
        or not is_typing
        or (
            requested_edit_count is not None
            and completed_edit_count == requested_edit_count
            and step_events == requested_edit_count
            and unicode_boundary_sample_counts["chinese"] > 0
            and unicode_boundary_sample_counts["emoji"] > 0
        )
    )

    render_path_interaction_valid = (
        native_rich_attachment_validation
        if uses_native_rich_presentation
        else len(apply_intervals) > 0
    )
    native_scroll_timing_valid = (
        not uses_native_rich_presentation or has_scroll_step_intervals
    )
    if is_manual:
        interaction_valid = (
            interaction_start is not None
            and interaction_end is not None
            and len(apply_intervals) > 0
            and cpu_samples > 0
            and document_utf16_length is not None
            and no_automatic_interaction_signposts
        )
    else:
        interaction_valid = (
            auto_start is not None
            and auto_end is not None
            and step_events > 0
            and render_path_interaction_valid
            and native_scroll_timing_valid
            and cpu_samples > 0
            and document_utf16_length is not None
            and typing_completion_valid
        )
    metric_gate_passed = (
        interaction_valid
        and apply_sample_count_sufficient
        and inline_attachment_sample_count_sufficient
        and p95_within_frame_budget
        and typing_step_p95_within_frame_budget
        and scroll_step_p95_within_frame_budget
        and no_blocking_hangs
        and no_tree_sitter_fallbacks
    )
    # A manual trace has no machine-verifiable interaction signpost. Keep its
    # metric result explicit, but never turn it into an automated performance
    # pass. The operator must review the trace and confirm that scrolling was
    # actually performed during the bounded capture window.
    performance_passed = metric_gate_passed and not is_manual
    latest_fallback = fallback_events[-1] if fallback_events else None
    report: dict[str, Any] = {
        "schemaVersion": 4,
        "interactionValid": interaction_valid,
        "interactionValidated": interaction_valid and not is_manual,
        "interactionDriver": interaction_driver,
        "manualReviewRequired": is_manual,
        "metricGatePassed": metric_gate_passed,
        "performancePassed": performance_passed,
        "scenario": scenario,
        "documentUTF16Length": document_utf16_length,
        "automaticScroll": None if is_typing or is_manual else {
            "durationMilliseconds": (
                round(milliseconds(auto_end - auto_start), 3)
                if auto_start is not None and auto_end is not None
                else None
            ),
            "stepEventCount": step_events,
            "pattern": scroll_pattern,
            "requestedCycleCount": requested_cycle_count,
            "completedCycleCount": completed_cycle_count,
            "stepIntervalCount": len(scroll_step_durations),
            "stepMedianMilliseconds": (
                round(statistics.median(scroll_step_durations), 3)
                if scroll_step_durations
                else None
            ),
            "stepP95Milliseconds": (
                round(scroll_step_p95_milliseconds, 3)
                if scroll_step_p95_milliseconds is not None
                else None
            ),
            "stepMaximumMilliseconds": (
                round(max(scroll_step_durations), 3)
                if scroll_step_durations
                else None
            ),
            "stepIntervalsWithinFrameBudget": scroll_step_p95_within_frame_budget,
        },
        "manualScroll": None if not is_manual or is_typing else {
            "analysisWindowDurationMilliseconds": (
                round(milliseconds(interaction_end - interaction_start), 3)
                if interaction_start is not None and interaction_end is not None
                else None
            ),
            "automaticInteractionDetected": automatic_interaction_signpost_count > 0,
            "manualReviewRequired": True,
            "operatorEvidenceRequired": True,
            "physicalInputIdentified": False,
        },
        "manualTyping": None if not is_manual or not is_typing else {
            "analysisWindowDurationMilliseconds": (
                round(milliseconds(interaction_end - interaction_start), 3)
                if interaction_start is not None and interaction_end is not None
                else None
            ),
            "automaticInteractionDetected": automatic_interaction_signpost_count > 0,
            "manualReviewRequired": True,
            "operatorEvidenceRequired": True,
            "inputSourceIdentified": False,
            "imeCandidateWindowTraceable": False,
        },
        "automaticTyping": {
            "durationMilliseconds": (
                round(milliseconds(auto_end - auto_start), 3)
                if is_typing and auto_start is not None and auto_end is not None
                else None
            ),
            "analysisWindowDurationMilliseconds": (
                round(milliseconds(interaction_analysis_end - auto_start), 3)
                if is_typing
                and auto_start is not None
                and interaction_analysis_end is not None
                else None
            ),
            "settleGraceMilliseconds": (
                DEFAULT_TYPING_SETTLE_GRACE_MILLISECONDS if is_typing else None
            ),
            "stepEventCount": step_events if is_typing else 0,
            "stepIntervalCount": len(typing_step_durations),
            "stepMedianMilliseconds": (
                round(statistics.median(typing_step_durations), 3)
                if typing_step_durations
                else None
            ),
            "stepP95Milliseconds": (
                round(typing_step_p95_milliseconds, 3)
                if typing_step_p95_milliseconds is not None
                else None
            ),
            "stepMaximumMilliseconds": (
                round(max(typing_step_durations), 3)
                if typing_step_durations
                else None
            ),
            "stepIntervalsWithinFrameBudget": typing_step_p95_within_frame_budget,
            "requestedEditCount": requested_edit_count,
            "completedEditCount": completed_edit_count,
            "completionCountMatches": (
                is_typing
                and requested_edit_count is not None
                and completed_edit_count == requested_edit_count
                and step_events == requested_edit_count
            ),
            "unicodeBoundarySampleCounts": unicode_boundary_sample_counts,
            "programmaticEditing": is_typing and not is_manual,
            "imeComposition": None if not is_typing or is_manual else False,
        },
        "applyAttributes": {
            "intervalCount": apply_sample_count,
            "minimumSampleCount": minimum_apply_samples,
            "sampleCountSufficient": apply_sample_count_sufficient,
            "medianMilliseconds": (
                round(statistics.median(apply_durations), 3) if apply_durations else None
            ),
            "p95Milliseconds": (
                round(percentile(apply_durations, 0.95) or 0, 3) if apply_durations else None
            ),
            "maximumMilliseconds": round(max(apply_durations), 3) if apply_durations else None,
            "frameBudgetMilliseconds": round(frame_budget_milliseconds, 3),
            "within60FPSFrameBudget": p95_within_frame_budget,
            "requiredByRenderPath": not uses_native_rich_presentation,
        },
        "applyAttributePhases": phase_metrics,
        "inlineAttachmentOverlays": {
            "intervalCount": inline_attachment_sample_count,
            "minimumSampleCount": minimum_inline_attachment_samples,
            "sampleCountSufficient": inline_attachment_sample_count_sufficient,
            "requiredByScenario": is_rich_scroll and not uses_native_rich_presentation,
        },
        "readOnlyPresentation": {
            "observedDuringInteraction": read_only_presentation_observed,
            "usesNativeRichPresentation": uses_native_rich_presentation,
            "showIntervalCount": len(read_only_show_records),
            "installedShowCount": len(installed_read_only_shows),
            "cacheHitShowCount": len(cached_read_only_shows),
            "cacheStatuses": read_only_cache_statuses,
            "showMedianMilliseconds": (
                round(statistics.median(read_only_show_durations), 3)
                if read_only_show_durations
                else None
            ),
            "showMaximumMilliseconds": (
                round(max(read_only_show_durations), 3)
                if read_only_show_durations
                else None
            ),
            "installedAttachmentCount": maximum_installed_attachment_count,
            "imageLoadEventCount": len(read_only_image_events),
            "scheduledImageLoadCount": maximum_scheduled_image_load_count,
            "nativeRichAttachmentValidation": native_rich_attachment_validation,
        },
        "treeSitterFallback": {
            "eventCount": fallback_event_count,
            "events": fallback_events,
            "latestReason": latest_fallback["reason"] if latest_fallback else None,
            "latestRange": latest_fallback["range"] if latest_fallback else None,
            "latestReportedCount": (
                latest_fallback["reportedCount"] if latest_fallback else None
            ),
        },
        # Keep a scalar for shell/CI consumers that only need the gate input.
        "treeSitterFallbackEventCount": fallback_event_count,
        "runningCPUSampleCount": cpu_samples,
        "validation": {
            "minimumApplySamples": minimum_apply_samples,
            "applySampleCountSufficient": apply_sample_count_sufficient,
            "minimumInlineAttachmentSamples": minimum_inline_attachment_samples,
            "inlineAttachmentSampleCountSufficient": (
                inline_attachment_sample_count_sufficient
            ),
            "frameBudgetMilliseconds": round(frame_budget_milliseconds, 3),
            "p95WithinFrameBudget": p95_within_frame_budget,
            "typingStepP95WithinFrameBudget": typing_step_p95_within_frame_budget,
            "scrollStepP95WithinFrameBudget": scroll_step_p95_within_frame_budget,
            "nativeScrollTimingValid": native_scroll_timing_valid,
            "nativeRichAttachmentValidation": native_rich_attachment_validation,
            "hangThresholdMilliseconds": round(hang_threshold_milliseconds, 3),
            "blockingHangCount": len(blocking_hangs),
            "noBlockingHangs": no_blocking_hangs,
            "treeSitterFallbackEventCount": fallback_event_count,
            "noTreeSitterFallbacks": no_tree_sitter_fallbacks,
            "typingCompletionValid": typing_completion_valid,
            "interactionDriver": interaction_driver,
            "automaticInteractionDetected": automatic_interaction_signpost_count > 0,
            "noAutomaticInteractionSignposts": no_automatic_interaction_signposts,
            "manualReviewRequired": is_manual,
            "metricGatePassed": metric_gate_passed,
        },
        "hangs": {
            "thresholdMilliseconds": round(hang_threshold_milliseconds, 3),
            "potentialHangCount": len(overlapping_hangs),
            "blockingHangCount": len(blocking_hangs),
            "ignoredLifecycleHangCount": len(ignored_lifecycle_hangs),
            "maximumMilliseconds": (
                round(max(hang["durationMilliseconds"] for hang in overlapping_hangs), 3)
                if overlapping_hangs
                else None
            ),
            "noBlockingHangs": no_blocking_hangs,
        },
        "environmentInterruptions": {
            "applicationDeactivationIntervalCount": len(application_deactivation_intervals),
            "fullyContainedHangCount": len(ignored_lifecycle_hangs),
        },
        "potentialHangsDuringScroll": overlapping_hangs if not is_typing else [],
        "potentialHangsDuringTyping": overlapping_hangs if is_typing else [],
    }
    return report, interaction_valid, performance_passed


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--scenario",
        choices=("markdown-scroll", "markdown-rich-scroll", "markdown-typing"),
        default="markdown-scroll",
        help=(
            "interaction represented by the signposts "
            "(default: markdown-scroll; rich attachments use markdown-rich-scroll)"
        ),
    )
    parser.add_argument(
        "--interaction-driver",
        choices=("programmatic", "manual"),
        default="programmatic",
        help=(
            "interaction driver; manual interaction reports metrics but always requires "
            "operator review and never becomes an automated performance pass"
        ),
    )
    parser.add_argument("--signposts", type=Path, required=True)
    parser.add_argument("--time-samples", type=Path, required=True)
    parser.add_argument("--hangs", type=Path, required=True)
    parser.add_argument(
        "--minimum-apply-samples",
        type=positive_integer,
        default=None,
        help=(
            "minimum ApplyAttributes intervals required for the performance gate "
            f"(default: {DEFAULT_MINIMUM_APPLY_SAMPLES} for markdown-scroll/markdown-rich-scroll, "
            f"{DEFAULT_TYPING_MINIMUM_APPLY_SAMPLES} for markdown-typing)"
        ),
    )
    parser.add_argument(
        "--frame-budget-ms",
        type=positive_float,
        default=DEFAULT_FRAME_BUDGET_MILLISECONDS,
        help=f"ApplyAttributes P95 budget in milliseconds (default: {DEFAULT_FRAME_BUDGET_MILLISECONDS})",
    )
    parser.add_argument(
        "--hang-threshold-ms",
        type=positive_float,
        default=DEFAULT_HANG_THRESHOLD_MILLISECONDS,
        help=f"blocking hang threshold in milliseconds (default: {DEFAULT_HANG_THRESHOLD_MILLISECONDS})",
    )
    parser.add_argument("--output", type=Path, required=True)
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    report, interaction_valid, performance_passed = analyze(arguments)
    arguments.output.write_text(
        json.dumps(report, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    print(json.dumps(report, ensure_ascii=False, indent=2))
    if not interaction_valid:
        return 2
    if arguments.interaction_driver == "manual":
        # A metric-only manual result is a successful capture, not an
        # automated performance pass. Keep exit 0 only when the measured
        # constraints pass; the JSON still carries performancePassed=false and
        # manualReviewRequired=true for the required human evidence.
        return 0 if report["metricGatePassed"] else 3
    return 0 if performance_passed else 3


if __name__ == "__main__":
    raise SystemExit(main())
