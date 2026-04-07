#!/usr/bin/env python3
"""Assemble stream-json JSONL into a single json-verbose response.

Reads JSONL from stdin (claude --output-format stream-json --verbose),
collects all events into a turns array, and outputs a single JSON object
that combines the final result with the full conversation history.
"""

import hashlib
import json
import sys

_CONTENT_TRUNCATE = 2000  # chars to keep before truncating


def _extract_tool_uses(content):
    """Extract tool_use entries from assistant message content."""
    out = []
    for block in content:
        if block.get("type") != "tool_use":
            continue
        entry = {
            "type": "tool_use",
            "id": block["id"],
            "name": block["name"],
            "input": block.get("input", {}),
        }
        out.append(entry)
    return out


def _extract_text(content):
    """Extract text blocks from assistant message content."""
    out = []
    for block in content:
        if block.get("type") != "text":
            continue
        out.append({"type": "text", "text": block["text"]})
    return out


def _truncate_content(text: str) -> dict:
    """Return content dict, truncating if over limit with sha256 + length."""
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
    """Extract tool_result entries from user message content."""
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
        entry = {
            "type": "tool_result",
            "tool_use_id": block.get("tool_use_id", ""),
            "is_error": block.get("is_error", False),
            **_truncate_content(text),
        }
        out.append(entry)
    return out


def assemble(lines):
    """Parse JSONL lines and return assembled json-verbose dict."""
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
            texts = _extract_text(content)
            tool_uses = _extract_tool_uses(content)
            parts = texts + tool_uses
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
            "is_error": True,
            "result": "no result event found in stream",
            "turns": turns,
        }

    result["turns"] = turns
    if system_init:
        result["system"] = system_init

    return result


def main():
    lines = sys.stdin.readlines()
    output = assemble(lines)
    json.dump(output, sys.stdout)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
