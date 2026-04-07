#!/usr/bin/env python3
"""JSON output normalizer for claude CLI.

Modes (pass as first arg):
  json          — read all stdin, parse as JSON, normalize keys, output
  stream-json   — read JSONL lines, normalize each, output immediately
  json-verbose  — read JSONL, assemble into single JSON with turns array
"""

import hashlib
import json
import sys

_CONTENT_TRUNCATE = 2000


def _to_camel(name: str) -> str:
    parts = name.split("_")
    return parts[0] + "".join(p.capitalize() for p in parts[1:])


def _normalize_keys(obj):
    if isinstance(obj, dict):
        return {_to_camel(k): _normalize_keys(v) for k, v in obj.items()}
    if isinstance(obj, list):
        return [_normalize_keys(item) for item in obj]
    return obj


def _normalize_line(line: str) -> str:
    line = line.strip()
    if not line:
        return ""
    try:
        parsed = json.loads(line)
        return json.dumps(_normalize_keys(parsed))
    except (json.JSONDecodeError, ValueError):
        return line


# ── json-verbose assembly ───────────────────────────────────────────────────


def _extract_tool_uses(content):
    out = []
    for block in content:
        if block.get("type") != "tool_use":
            continue
        out.append(
            {
                "type": "tool_use",
                "id": block["id"],
                "name": block["name"],
                "input": block.get("input", {}),
            }
        )
    return out


def _extract_text(content):
    out = []
    for block in content:
        if block.get("type") != "text":
            continue
        out.append({"type": "text", "text": block["text"]})
    return out


def _truncate_content(text: str) -> dict:
    if len(text) <= _CONTENT_TRUNCATE:
        return {"content": text}
    sha = hashlib.sha256(text.encode()).hexdigest()
    return {
        "content": text[:_CONTENT_TRUNCATE],
        "truncated": True,
        "total_length": len(text),
        "sha256": sha,
    }


def _extract_tool_results(content):
    out = []
    for block in content:
        if block.get("type") != "tool_result":
            continue
        raw = block.get("content", "")
        if isinstance(raw, str):
            text = raw
        elif isinstance(raw, list):
            texts = [b.get("text", "") for b in raw if b.get("type") == "text"]
            text = "\n".join(texts) if texts else str(raw)
        else:
            text = str(raw)
        out.append(
            {
                "type": "tool_result",
                "tool_use_id": block.get("tool_use_id", ""),
                "is_error": block.get("is_error", False),
                **_truncate_content(text),
            }
        )
    return out


def _assemble(lines):
    turns = []
    result = None
    system_init = None

    for line in lines:
        line = line.strip()
        if not line:
            continue
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue

        etype = event.get("type", "")

        if etype == "system" and event.get("subtype") == "init":
            system_init = {
                "session_id": event.get("session_id", ""),
                "model": event.get("model", ""),
                "cwd": event.get("cwd", ""),
                "tools": event.get("tools", []),
            }
            continue

        if etype == "assistant":
            msg = event.get("message", {})
            content = msg.get("content", [])
            parts = _extract_text(content) + _extract_tool_uses(content)
            if not parts:
                continue
            turns.append({"role": "assistant", "content": parts})
            continue

        if etype == "user":
            msg = event.get("message", {})
            content = msg.get("content", [])
            tool_results = _extract_tool_results(content)
            if not tool_results:
                continue
            turns.append({"role": "tool_result", "content": tool_results})
            continue

        if etype == "result":
            result = event
            continue

    if not result:
        return {
            "type": "result",
            "subtype": "error",
            "isError": True,
            "result": "no result event found in stream",
            "turns": turns,
        }

    result["turns"] = turns
    if system_init:
        result["system"] = system_init

    return _normalize_keys(result)


# ── main ────────────────────────────────────────────────────────────────────


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "json"

    if mode == "stream-json":
        for line in sys.stdin:
            normalized = _normalize_line(line)
            if normalized:
                sys.stdout.write(normalized + "\n")
                sys.stdout.flush()
        return

    if mode == "json-verbose":
        lines = sys.stdin.readlines()
        output = _assemble(lines)
        json.dump(output, sys.stdout)
        sys.stdout.write("\n")
        return

    # json mode — read all, normalize
    raw = sys.stdin.read().strip()
    if not raw:
        return
    sys.stdout.write(_normalize_line(raw) + "\n")


if __name__ == "__main__":
    main()
