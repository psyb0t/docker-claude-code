#!/usr/bin/env python3

import asyncio
import os
import signal
from typing import Optional

import uvicorn
from fastapi import FastAPI, Header, HTTPException, Query, Request
from fastapi.responses import FileResponse, Response
from pydantic import BaseModel

app = FastAPI()


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
    prompt: str
    workspace: Optional[str] = None
    model: Optional[str] = None
    system_prompt: Optional[str] = None
    append_system_prompt: Optional[str] = None
    json_schema: Optional[str] = None
    effort: Optional[str] = None
    no_continue: bool = False
    resume: Optional[str] = None


def _build_args(req: RunRequest, with_continue: bool = False):
    args = ["claude", "--dangerously-skip-permissions"]
    if req.resume:
        args += ["--resume", req.resume]
    elif with_continue and not req.no_continue:
        args.append("--continue")
    args += ["-p", req.prompt, "--output-format", "json"]
    if req.model:
        args += ["--model", req.model]
    if req.system_prompt:
        args += ["--system-prompt", req.system_prompt]
    if req.append_system_prompt:
        args += ["--append-system-prompt", req.append_system_prompt]
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
            )
            busy_workspaces[workspace] = proc
            if proc.stdout:
                async for line in proc.stdout:
                    yield line
            await proc.wait()
    finally:
        busy_workspaces.pop(workspace, None)


@app.post("/run")
async def run(req: RunRequest, authorization: Optional[str] = Header(None)):
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

    output = b""
    async for chunk in _stream(workspace, req):
        output += chunk

    return Response(content=output, media_type="application/json")


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
