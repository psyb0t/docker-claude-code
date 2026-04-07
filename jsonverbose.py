#!/usr/bin/env python3
"""Assemble stream-json JSONL into a single json-verbose response.

Reads JSONL from stdin (claude --output-format stream-json --verbose),
collects all events into a turns array, and outputs a single JSON object
that combines the final result with the full conversation history.
"""

import json
import sys


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


def _extract_tool_results(content):
    """Extract tool_result entries from user message content."""
    out = []
    for block in content:
        if block.get("type") != "tool_result":
            continue
        entry = {
            "type": "tool_result",
            "tool_use_id": block.get("tool_use_id", ""),
            "is_error": block.get("is_error", False),
        }
        raw = block.get("content", "")
        if isinstance(raw, str):
            entry["content"] = raw
        elif isinstance(raw, list):
            # content can be a list of blocks
            texts = [b.get("text", "") for b in raw if b.get("type") == "text"]
            entry["content"] = "\n".join(texts) if texts else str(raw)
        else:
            entry["content"] = str(raw)
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
