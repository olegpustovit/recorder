#!/usr/bin/env python3
"""T-833 agent eval: score MCP client transcripts (JSONL, one JSON-RPC message per line) for the brief
"30 s reel, fast cuts, no text". Metrics per transcript: tool calls, edit ops (dryRun false, ok responses),
images returned by render.* calls, final lint pass, final duration from the last report.

Usage: scripts/agent-eval.py [--json] [--pref label=0.7 ...] transcript.jsonl [...]
       scripts/agent-eval.py --selftest
"""
import argparse
import json
import os
import sys

WARN_SEVS = ("error", "warn")  # lint items at these severities fail a transcript


def score(label, lines):
    m = {"label": label, "toolCalls": 0, "ops": 0, "images": 0, "lintPass": None, "duration": None}
    pending = {}  # request id -> tools/call params
    for line in lines:
        if not line.strip():
            continue
        msg = json.loads(line)
        if msg.get("method") == "tools/call":
            pending[msg.get("id")] = msg["params"]
            m["toolCalls"] += 1
            continue
        call = pending.pop(msg.get("id"), None)
        if call is None or "result" not in msg:
            continue
        res = msg["result"]
        args = call.get("arguments", {})
        action = args.get("action", "")
        tool = f"{call['name']}.{action}" if action else call["name"]
        ok = not res.get("isError", False)
        if tool == "edit.apply" and ok and not args.get("dryRun", False):
            m["ops"] += len(args.get("ops", []))
        if call["name"] == "render" and ok:
            n_img = sum(1 for c in res.get("content", []) if c.get("type") == "image")
            if n_img:
                at = args.get("at")
                n = len(at) if isinstance(at, list) else args.get("count", 1)
                m["images"] += n
        sc = res.get("structuredContent", {})
        if isinstance(sc.get("lint"), list):
            m["lintPass"] = not any(i.get("sev") in WARN_SEVS for i in sc["lint"])
        d = (sc.get("report") or {}).get("duration", sc.get("duration"))
        if isinstance(d, dict):
            d = d.get("after")
        if isinstance(d, (int, float)):
            m["duration"] = d
    return m


def summarize(rows, prefs):
    lint = [r["lintPass"] for r in rows if r["lintPass"] is not None]
    dur = [r["duration"] for r in rows if r["duration"] is not None]
    mean = lambda xs: sum(xs) / len(xs) if xs else None
    return {
        "transcripts": len(rows),
        "meanToolCalls": mean([r["toolCalls"] for r in rows]),
        "meanOps": mean([r["ops"] for r in rows]),
        "meanImages": mean([r["images"] for r in rows]),
        "lintPassRate": sum(lint) / len(lint) if lint else None,
        "meanDuration": mean(dur),
        "meanPref": mean([prefs[r["label"]] for r in rows if r["label"] in prefs]),
    }


def table(rows, summary):
    def f(x, fmt="{:.1f}"):
        return "-" if x is None else fmt.format(x)

    out = [f"{'transcript':<16}{'calls':>6}{'ops':>6}{'images':>8}{'lint':>7}{'dur(s)':>8}{'pref':>7}"]
    for r in rows:
        lint = "-" if r["lintPass"] is None else ("PASS" if r["lintPass"] else "FAIL")
        pref = r.get("pref")
        out.append(f"{r['label']:<16}{r['toolCalls']:>6}{r['ops']:>6}{r['images']:>8}{lint:>7}"
                   f"{f(r['duration']):>8}{f(pref, '{:.2f}'):>7}")
    s = summary
    out.append(f"{'mean':<16}{f(s['meanToolCalls']):>6}{f(s['meanOps']):>6}{f(s['meanImages']):>8}"
               f"{f(s['lintPassRate'], '{:.0%}'):>7}{f(s['meanDuration']):>8}{f(s['meanPref'], '{:.2f}'):>7}")
    return "\n".join(out)


def selftest():
    def call(i, name, **args):
        return json.dumps({"jsonrpc": "2.0", "id": i, "method": "tools/call", "params": {"name": name, "arguments": args}})

    def reply(i, sc=None, images=0, is_error=False):
        content = [{"type": "text", "text": "{}"}] + [{"type": "image", "mimeType": "image/png", "data": ""}] * images
        return json.dumps({"jsonrpc": "2.0", "id": i, "result": {"isError": is_error, "content": content,
                                                                 "structuredContent": sc or {}}})

    a = [
        call(1, "project", action="open"), reply(1),
        call(2, "edit", action="apply", ops=[{"op": "cut"}, {"op": "speed"}]),
        reply(2, {"lint": [{"sev": "info"}], "report": {"duration": {"before": 30, "after": 27}}}),
        call(3, "edit", action="apply", dryRun=True, ops=[{"op": "cut"}]),
        reply(3, {"lint": [{"sev": "warn"}]}),
        call(4, "render", action="frames", at=[1, 2, 3]), reply(4, images=3),
        call(5, "render", action="lint"), reply(5, {"lint": [{"sev": "info", "rule": "hook"}]}),
    ]
    b = [
        call(1, "edit", action="apply", ops=[{"op": "cut"}, {"op": "cut"}, {"op": "cutPauses"}]),
        reply(1, {"lint": [{"sev": "warn", "rule": "maxStatic"}], "report": {"duration": {"before": 30, "after": 25}}}),
        call(2, "edit", action="apply", ops=[{"op": "cut"}] * 4), reply(2, {"error": "INVALID_OP"}, is_error=True),
        call(3, "render", action="sheet", count=12), reply(3, images=1),
    ]
    rows = [score("runA", a), score("runB", b)]
    rows[0]["pref"], rows[1]["pref"] = 0.7, None
    got = [(r["toolCalls"], r["ops"], r["images"], r["lintPass"], r["duration"]) for r in rows]
    assert got[0] == (5, 2, 3, True, 27), got[0]
    assert got[1] == (3, 3, 12, False, 25), got[1]
    s = summarize(rows, {"runA": 0.7})
    assert s["transcripts"] == 2 and s["lintPassRate"] == 0.5, s
    assert s["meanOps"] == 2.5 and s["meanImages"] == 7.5 and s["meanPref"] == 0.7, s
    assert s["meanDuration"] == 26, s
    table(rows, s)
    print("agent-eval selftest passed: 2 synthetic transcripts, metrics and summary asserted")


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("transcripts", nargs="*", help="MCP client transcripts (JSONL)")
    p.add_argument("--json", action="store_true", help="also print the JSON summary")
    p.add_argument("--pref", action="append", default=[], metavar="LABEL=VALUE",
                   help="human preference vs hand edit for a transcript (manual column)")
    p.add_argument("--selftest", action="store_true", help="check the metrics on built-in synthetic transcripts")
    args = p.parse_args()
    if args.selftest:
        return selftest()
    if not args.transcripts:
        p.error("give at least one transcript (or --selftest)")
    prefs = {}
    for item in args.pref:
        k, _, v = item.partition("=")
        try:
            prefs[k] = float(v)
        except ValueError:
            p.error(f"--pref wants LABEL=VALUE, got {item!r}")
    rows = []
    for path in args.transcripts:
        label = os.path.splitext(os.path.basename(path))[0]
        with open(path, encoding="utf-8") as fh:
            row = score(label, fh)
        row["pref"] = prefs.get(label)
        rows.append(row)
    summary = summarize(rows, prefs)
    print(table(rows, summary))
    if args.json:
        print(json.dumps({"transcripts": rows, "summary": summary}, indent=2))


if __name__ == "__main__":
    sys.exit(main())
