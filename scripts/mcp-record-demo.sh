#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec python3 - "${1:-$root/build/Recorder.app/Contents/MacOS/Recorder}" <<'PY'
import itertools
import json
import subprocess
import sys
import time

with subprocess.Popen([sys.argv[1], "--mcp"], stdin=subprocess.PIPE,
                      stdout=subprocess.PIPE, text=True, encoding="utf-8") as shim:
    ids = itertools.count(1)

    def send(method, params, request_id=None):
        message = {"jsonrpc": "2.0", "method": method, "params": params}
        if request_id is not None:
            message["id"] = request_id
        shim.stdin.write(json.dumps(message) + "\n")
        shim.stdin.flush()

    def request(method, params):
        request_id = next(ids)
        send(method, params, request_id)
        for line in shim.stdout:
            reply = json.loads(line)
            if reply.get("id") != request_id:
                continue
            if "error" in reply:
                sys.exit(reply["error"]["message"])
            return reply["result"]
        sys.exit(f"Recorder MCP disconnected during {method}")

    def record(action, **args):
        result = request("tools/call", {"name": "record", "arguments": {"action": action, **args}})
        payload = result["structuredContent"]
        if result.get("isError"):
            sys.exit(f'{payload["error"]}: {payload["message"]}')
        return payload

    request("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                           "clientInfo": {"name": "Recorder capture demo", "version": "1"}})
    send("notifications/initialized", {})
    display = next((d for d in record("targets")["displays"] if d["main"]), None)
    if display is None or display["width"] < 800 or display["height"] < 600:
        sys.exit("The demo needs a main display at least 800 × 600 points")
    print("Waiting for Recorder to start capture. Approve the native prompt if shown.", file=sys.stderr)
    record("start", display=display["id"], area={"x": 0, "y": 0, "width": 800, "height": 600},
           title="Agent recording demo", maxDuration=30)
    time.sleep(3)
    record("mark", label="demo")
    time.sleep(2)
    print(record("stop")["project"])
PY
