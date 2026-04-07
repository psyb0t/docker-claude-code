#!/usr/bin/env python3

import asyncio
import json
import os
import signal
from typing import Optional

import uvicorn
from fastapi import FastAPI, Header, HTTPException, Query, Request
from fastapi.responses import FileResponse, Response
from pydantic import BaseModel, ConfigDict, Field

from jsonverbose import assemble  # noqa: E402

app = FastAPI()


def _to_camel(name: str) -> str:
    """Convert a snake_case string to camelCase."""
    parts = name.split("_")
    return parts[0] + "".join(p.capitalize() for p in parts[1:])


def _normalize_keys(obj):
    """Recursively convert all dict keys from snake_case to camelCase."""
    if isinstance(obj, dict):
        return {_to_camel(k): _normalize_keys(v) for k, v in obj.items()}
    if isinstance(obj, list):
        return [_normalize_keys(item) for item in obj]
    return obj


def _normalize_response(raw: bytes) -> bytes:
    """Parse raw JSON bytes, normalize keys to camelCase, return bytes."""
    try:
        parsed = json.loads(raw)
        normalized = _normalize_keys(parsed)
        return json.dumps(normalized).encode()
    except (json.JSONDecodeError, ValueError):
        return raw


def _shutdown(sig, _frame):
    for ws, proc in list(busy_workspaces.items()):
        try:
            proc.terminate()
        except ProcessLookupError:
            pass
    raise SystemExit(0)


signal.signal(signal.SIGTERM, _shutdown)
signal.signal(signal.SIGINT, _shutdown)

ROOT_WORKSPACE = "/workspaces"
CLAUDE_MD_TEMPLATE = "/home/claude/.claude/CLAUDE.md.template"
SYSTEM_HINT_FILE = "/home/claude/.claude/system-hint.txt"
SYSTEM_HINT = ""
if os.path.isfile(SYSTEM_HINT_FILE):
    with open(SYSTEM_HINT_FILE) as _f:
        SYSTEM_HINT = _f.read().strip()

API_TOKEN = os.environ.get("CLAUDE_MODE_API_TOKEN", "")
PORT = int(os.environ.get("CLAUDE_MODE_API_PORT", "8080"))

busy_workspaces: dict[str, asyncio.subprocess.Process] = {}


def _check_auth(authorization: Optional[str]):
    if not API_TOKEN:
        return
    if not authorization or authorization != f"Bearer {API_TOKEN}":
        raise HTTPException(status_code=401, detail="unauthorized")


def _resolve_workspace(workspace: Optional[str]) -> str:
    sub = workspace.lstrip("/") if workspace else ""
    resolved = os.path.join(ROOT_WORKSPACE, sub) if sub else ROOT_WORKSPACE
    resolved = os.path.realpath(resolved)
    if not resolved.startswith(os.path.realpath(ROOT_WORKSPACE)):
        raise HTTPException(status_code=400, detail="path outside root workspace")
    return resolved


def _resolve_path(path: str) -> str:
    full = os.path.realpath(os.path.join(ROOT_WORKSPACE, path.lstrip("/")))
    if not full.startswith(os.path.realpath(ROOT_WORKSPACE)):
        raise HTTPException(status_code=400, detail="path outside root workspace")
    return full


class RunRequest(BaseModel):
    model_config = ConfigDict(populate_by_name=True)

    prompt: str
    workspace: Optional[str] = None
    model: Optional[str] = None
    system_prompt: Optional[str] = Field(None, alias="systemPrompt")
    append_system_prompt: Optional[str] = Field(None, alias="appendSystemPrompt")
    json_schema: Optional[str] = Field(None, alias="jsonSchema")
    effort: Optional[str] = None
    output_format: Optional[str] = Field(None, alias="outputFormat")
    no_continue: bool = Field(False, alias="noContinue")
    resume: Optional[str] = None
    fire_and_forget: bool = Field(False, alias="fireAndForget")


def _build_args(req: RunRequest, with_continue: bool = False):
    args = ["claude", "--dangerously-skip-permissions"]
    if req.resume:
        args += ["--resume", req.resume]
    elif with_continue and not req.no_continue:
        args.append("--continue")
    if req.output_format == "json-verbose":
        args += ["-p", req.prompt, "--output-format", "stream-json", "--verbose"]
    else:
        args += ["-p", req.prompt, "--output-format", "json"]
    if req.model:
        args += ["--model", req.model]
    if req.system_prompt:
        args += ["--system-prompt", req.system_prompt]
    # always append system hint + any user append
    append_parts = []
    if SYSTEM_HINT:
        append_parts.append(SYSTEM_HINT)
    if req.append_system_prompt:
        append_parts.append(req.append_system_prompt)
    if append_parts:
        args += ["--append-system-prompt", "\n".join(append_parts)]
    if req.json_schema:
        args += ["--json-schema", req.json_schema]
    if req.effort:
        args += ["--effort", req.effort]
    return args


def _build_env():
    return {
        **os.environ,
        "HOME": "/home/claude",
        "CLAUDE_CONFIG_DIR": "/home/claude/.claude",
        "PATH": f"/home/claude/.claude/bin:/home/claude/.local/bin:{os.environ.get('PATH', '')}",
    }


_STREAM_LIMIT = 100 * 1024 * 1024  # 100MB — claude lines can be huge


async def _stream(workspace: str, req: RunRequest):
    env = _build_env()

    try:
        if req.no_continue or req.resume:
            proc = await asyncio.create_subprocess_exec(
                *_build_args(req, with_continue=False),
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.STDOUT,
                cwd=workspace,
                env=env,
                limit=_STREAM_LIMIT,
            )
            busy_workspaces[workspace] = proc
            if proc.stdout:
                async for line in proc.stdout:
                    yield line
            await proc.wait()
            return

        # try with --continue first, fall back without
        proc = await asyncio.create_subprocess_exec(
            *_build_args(req, with_continue=True),
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.STDOUT,
            cwd=workspace,
            env=env,
            limit=_STREAM_LIMIT,
        )
        busy_workspaces[workspace] = proc

        output = b""
        if proc.stdout:
            async for line in proc.stdout:
                output += line
                yield line
        await proc.wait()

        if proc.returncode != 0 and not output:
            proc = await asyncio.create_subprocess_exec(
                *_build_args(req, with_continue=False),
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.STDOUT,
                cwd=workspace,
                env=env,
                limit=_STREAM_LIMIT,
            )
            busy_workspaces[workspace] = proc
            if proc.stdout:
                async for line in proc.stdout:
                    yield line
            await proc.wait()
    finally:
        busy_workspaces.pop(workspace, None)


@app.post("/run")
async def run(
    request: Request,
    req: RunRequest,
    authorization: Optional[str] = Header(None),
):
    _check_auth(authorization)

    workspace = _resolve_workspace(req.workspace)

    if not os.path.isdir(workspace):
        raise HTTPException(status_code=400, detail=f"workspace not found: {workspace}")

    # seed CLAUDE.md from template if missing
    claude_md = os.path.join(workspace, "CLAUDE.md")
    if not os.path.isfile(claude_md) and os.path.isfile(CLAUDE_MD_TEMPLATE):
        import shutil

        shutil.copy2(CLAUDE_MD_TEMPLATE, claude_md)

    if workspace in busy_workspaces:
        raise HTTPException(status_code=409, detail="workspace busy, retry later")

    busy_workspaces[workspace] = None  # type: ignore[assignment]

    watcher = None
    if not req.fire_and_forget:

        async def _disconnect_watcher():
            """Kill the claude process if the client disconnects."""
            while workspace in busy_workspaces:
                if await request.is_disconnected():
                    proc = busy_workspaces.get(workspace)
                    if proc:
                        proc.kill()
                    return
                await asyncio.sleep(1)

        watcher = asyncio.create_task(_disconnect_watcher())

    output = b""
    try:
        async for chunk in _stream(workspace, req):
            output += chunk
    finally:
        if watcher:
            watcher.cancel()

    if not req.fire_and_forget and await request.is_disconnected():
        return Response(status_code=499)

    if req.output_format == "json-verbose":
        lines = output.decode().splitlines()
        assembled = assemble(lines)
        content = json.dumps(assembled).encode()
    else:
        content = _normalize_response(output)

    return Response(content=content, media_type="application/json")


@app.get("/files/{path:path}")
@app.get("/files")
async def get_files(
    path: str = "",
    authorization: Optional[str] = Header(None),
):
    _check_auth(authorization)

    full = _resolve_path(path) if path else os.path.realpath(ROOT_WORKSPACE)

    if not os.path.exists(full):
        raise HTTPException(status_code=404, detail=f"not found: {path}")

    if os.path.isdir(full):
        entries = []
        for name in sorted(os.listdir(full)):
            entry_path = os.path.join(full, name)
            entry: dict = {
                "name": name,
                "type": "dir" if os.path.isdir(entry_path) else "file",
            }
            if entry["type"] == "file":
                entry["size"] = os.path.getsize(entry_path)
            entries.append(entry)
        return {"path": path or "/", "entries": entries}

    return FileResponse(full)


@app.put("/files/{path:path}")
async def put_files(
    request: Request,
    path: str,
    authorization: Optional[str] = Header(None),
):
    _check_auth(authorization)

    full = _resolve_path(path)

    os.makedirs(os.path.dirname(full), exist_ok=True)

    body = await request.body()
    with open(full, "wb") as f:
        f.write(body)

    return {"status": "ok", "path": full, "size": len(body)}


@app.delete("/files/{path:path}")
async def delete_files(
    path: str,
    authorization: Optional[str] = Header(None),
):
    _check_auth(authorization)

    full = _resolve_path(path)

    if not os.path.exists(full):
        raise HTTPException(status_code=404, detail=f"not found: {path}")

    if os.path.isdir(full):
        raise HTTPException(status_code=400, detail="cannot delete directories")

    os.remove(full)

    return {"status": "ok", "path": full}


@app.get("/health")
async def health():
    return {"status": "ok"}


@app.get("/status")
async def status(authorization: Optional[str] = Header(None)):
    _check_auth(authorization)

    return {
        "busy_workspaces": list(busy_workspaces.keys()),
    }


@app.post("/run/cancel")
async def cancel_run(
    workspace: Optional[str] = Query(None),
    authorization: Optional[str] = Header(None),
):
    _check_auth(authorization)

    ws = _resolve_workspace(workspace)

    proc = busy_workspaces.get(ws)
    if not proc:
        raise HTTPException(status_code=404, detail="no running process for workspace")

    proc.kill()
    await proc.wait()

    return {"status": "ok", "workspace": ws}


if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=PORT)
