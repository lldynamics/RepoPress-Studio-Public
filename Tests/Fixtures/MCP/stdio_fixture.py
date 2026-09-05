#!/usr/bin/python3
"""A deterministic JSON-RPC stdio MCP fixture with no third-party imports."""

import json
import os
import subprocess
import sys
import time


launch_counter_path = os.environ.get("MCP_TEST_LAUNCH_COUNTER")
if launch_counter_path:
    with open(launch_counter_path, "a", encoding="utf-8") as counter:
        counter.write("launch\n")


if len(sys.argv) == 3 and sys.argv[1] == "--record-descendant-and-exit":
    child = subprocess.Popen(
        [
            sys.executable,
            "-c",
            "import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(30)",
        ],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        close_fds=True,
    )
    with open(sys.argv[2], "w", encoding="utf-8") as record:
        record.write(str(child.pid))
        record.flush()
        os.fsync(record.fileno())
    os._exit(0)


def reply(request_id, result):
    sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": request_id, "result": result}) + "\n")
    sys.stdout.flush()


def tool_schema():
    return {
        "name": "echo",
        "description": "Returns its text input.",
        "inputSchema": {
            "type": "object",
            "properties": {"text": {"type": "string"}},
            "required": ["text"],
        },
    }


for line in sys.stdin:
    message = json.loads(line)
    method = message.get("method")
    request_id = message.get("id")
    params = message.get("params", {})
    if method == "initialize":
        reply(request_id, {
            "protocolVersion": params.get("protocolVersion", "2025-03-26"),
            "capabilities": {"tools": {}},
            "serverInfo": {"name": "fixture", "version": "1"},
        })
    elif method == "notifications/initialized":
        continue
    elif method == "tools/list":
        reply(request_id, {"tools": [tool_schema()]})
    elif method == "tools/call":
        arguments = params.get("arguments", {})
        text = arguments.get("text", "")
        if text == "secret":
            text = os.environ.get("MCP_TEST_SECRET", "missing")
        elif text == "sleep":
            time.sleep(2)
            text = "finished"
        elif text == "exit":
            sys.exit(7)
        elif text == "image":
            reply(request_id, {"content": [{"type": "image", "data": "AA==", "mimeType": "image/png"}]})
            continue
        elif text == "large":
            text = "x" * 4096
        elif text == "large_valid_frame":
            text = "x" * (96 * 1024)
        elif text == "valid_frame_flood":
            frame = (
                json.dumps({
                    "jsonrpc": "2.0",
                    "method": "notifications/progress",
                    "params": {"progressToken": "flood", "progress": 1},
                })
                + "\n"
            )
            while True:
                sys.stdout.write(frame * 64)
                sys.stdout.flush()
        elif text == "structured":
            reply(request_id, {
                "content": [],
                "structuredContent": {"value": "must-not-be-silently-dropped"},
            })
            continue
        elif text == "empty_blocks":
            reply(request_id, {
                "content": [{"type": "text", "text": ""} for _ in range(256)],
            })
            continue
        elif text == "raw_frame":
            sys.stdout.write("x" * 4096)
            sys.stdout.flush()
            continue
        elif text == "process_identity":
            text = f"pid:{os.getpid()},pgrp:{os.getpgrp()}"
        elif text in {"descendant", "descendant_exit"}:
            child = subprocess.Popen(
                [
                    sys.executable,
                    "-c",
                    "import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(30)",
                ],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                close_fds=True,
            )
            text = f"pid:{child.pid}"
        reply(request_id, {"content": [{"type": "text", "text": text}]})
        if arguments.get("text") == "descendant_exit":
            os._exit(0)
