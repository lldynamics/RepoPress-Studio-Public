#!/usr/bin/env python3
"""Fail when the Linux CI jobs stop exercising the distro-backed OCR boundary."""

from __future__ import annotations

import re
import shlex
import sys
from pathlib import Path


TARGET_JOBS = {
    "ubuntu": "ubuntu-24.04",
    "linux-release-bundle": "ubuntu-22.04",
}
OCR_PACKAGES = {
    "bubblewrap",
    "poppler-utils",
    "tesseract-ocr",
    "tesseract-ocr-eng",
    "tesseract-ocr-chi-sim",
}
OCR_TEST = "real_bubblewrap_pdftoppm_and_tesseract_ocr"
PDF_TEXT_TEST = "real_bubblewrap_and_pdftotext_extract_text"
EXPECTED_OCR_COMMAND = [
    "cargo",
    "test",
    "--manifest-path",
    "src-tauri/Cargo.toml",
    "--locked",
    OCR_TEST,
]


class WorkflowError(RuntimeError):
    pass


def indentation(line: str) -> int:
    return len(line) - len(line.lstrip(" "))


def mapping_block(lines: list[str], key: str, indent: int) -> list[str]:
    header = " " * indent + key + ":"
    try:
        start = next(index for index, line in enumerate(lines) if line.rstrip() == header)
    except StopIteration as exc:
        raise WorkflowError(f"missing {key!r} mapping") from exc

    end = len(lines)
    for index in range(start + 1, len(lines)):
        line = lines[index]
        if line.strip() and not line.lstrip().startswith("#") and indentation(line) <= indent:
            end = index
            break
    return lines[start:end]


def job_blocks(workflow_lines: list[str]) -> dict[str, list[str]]:
    jobs = mapping_block(workflow_lines, "jobs", 0)
    headers: list[tuple[int, str]] = []
    for index, line in enumerate(jobs):
        match = re.fullmatch(r"  ([A-Za-z0-9_-]+):\s*(?:#.*)?", line)
        if match:
            headers.append((index, match.group(1)))

    blocks: dict[str, list[str]] = {}
    for header_index, (start, name) in enumerate(headers):
        end = headers[header_index + 1][0] if header_index + 1 < len(headers) else len(jobs)
        blocks[name] = jobs[start:end]
    return blocks


def step_blocks(job: list[str]) -> list[list[str]]:
    starts = [
        index
        for index, line in enumerate(job)
        if re.match(r"^      -\s+", line)
    ]
    return [
        job[start : starts[index + 1] if index + 1 < len(starts) else len(job)]
        for index, start in enumerate(starts)
    ]


def step_name(step: list[str]) -> str:
    match = re.match(r"^      - name:\s*(.*?)\s*$", step[0])
    return match.group(1).strip("\"'") if match else "<unnamed>"


def run_words(step: list[str]) -> list[str]:
    for index, line in enumerate(step):
        match = re.match(r"^        run:\s*(.*?)\s*$", line)
        if not match:
            continue

        scalar = match.group(1)
        if scalar in {"|", "|-", "|+", ">", ">-", ">+"}:
            command_lines = step[index + 1 :]
        else:
            command_lines = [scalar]

        normalized: list[str] = []
        for command_line in command_lines:
            stripped = command_line.strip()
            if not stripped or stripped.startswith("#"):
                continue
            if stripped.endswith("\\"):
                stripped = stripped[:-1].rstrip()
            normalized.append(stripped)
        try:
            return shlex.split(" ".join(normalized), comments=True)
        except ValueError as exc:
            raise WorkflowError(f"cannot parse run command in {step_name(step)!r}: {exc}") from exc
    return []


def require_read_only_permissions(workflow_lines: list[str]) -> None:
    permissions = [
        line.strip()
        for line in mapping_block(workflow_lines, "permissions", 0)[1:]
        if line.strip() and not line.lstrip().startswith("#")
    ]
    if permissions != ["contents: read"]:
        raise WorkflowError(
            "desktop workflow permissions must remain exactly 'contents: read'"
        )


def check_job(job_name: str, expected_runner: str, job: list[str]) -> None:
    job_text = "\n".join(job)
    if not re.search(rf"^    runs-on:\s*{re.escape(expected_runner)}\s*$", job_text, re.MULTILINE):
        raise WorkflowError(f"{job_name}: expected runner {expected_runner}")

    steps = step_blocks(job)
    install_steps = [
        step
        for step in steps
        if "apt-get" in run_words(step) and "update" in run_words(step)
    ]
    if len(install_steps) != 1:
        raise WorkflowError(f"{job_name}: expected one apt dependency step")
    installed_words = set(run_words(install_steps[0]))
    missing_packages = sorted(OCR_PACKAGES - installed_words)
    if missing_packages:
        raise WorkflowError(
            f"{job_name}: OCR dependency step is missing {', '.join(missing_packages)}"
        )

    ocr_steps = [
        step
        for step in steps
        if OCR_TEST in run_words(step)
    ]
    if len(ocr_steps) != 1:
        raise WorkflowError(f"{job_name}: expected exactly one OCR integration step")

    ocr_step = ocr_steps[0]
    name = step_name(ocr_step)
    if "ocr" not in name.lower():
        raise WorkflowError(f"{job_name}: OCR integration step must be clearly named")
    if PDF_TEXT_TEST in run_words(ocr_step):
        raise WorkflowError(f"{job_name}: OCR and pdftotext gates must be separate steps")
    if run_words(ocr_step) != EXPECTED_OCR_COMMAND:
        raise WorkflowError(
            f"{job_name}: OCR integration command must be exactly "
            + " ".join(EXPECTED_OCR_COMMAND)
        )
    if not re.search(
        r'^          REPOPRESS_RUN_DOCUMENT_INTEGRATION:\s*["\']?1["\']?\s*$',
        "\n".join(ocr_step),
        re.MULTILINE,
    ):
        raise WorkflowError(f"{job_name}: OCR integration opt-in is missing")


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {Path(sys.argv[0]).name} WORKFLOW", file=sys.stderr)
        return 2

    workflow_path = Path(sys.argv[1])
    workflow_text = workflow_path.read_text(encoding="utf-8")
    workflow_lines = workflow_text.splitlines()

    if "\t" in workflow_text:
        raise WorkflowError("workflow must not contain tab indentation")
    if "secrets." in workflow_text:
        raise WorkflowError("desktop workflow must not expose secrets to build or OCR jobs")
    if workflow_text.count(OCR_TEST) != len(TARGET_JOBS):
        raise WorkflowError("workflow must contain exactly two OCR integration invocations")

    require_read_only_permissions(workflow_lines)
    jobs = job_blocks(workflow_lines)
    for job_name, runner in TARGET_JOBS.items():
        try:
            job = jobs[job_name]
        except KeyError as exc:
            raise WorkflowError(f"missing required Linux job {job_name!r}") from exc
        check_job(job_name, runner, job)

    print("Linux OCR workflow gate passed.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except WorkflowError as exc:
        print(f"Linux OCR workflow gate failed: {exc}", file=sys.stderr)
        raise SystemExit(1) from exc
