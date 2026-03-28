#!/usr/bin/env python3

import asyncio
import os
from typing import Optional

import uvicorn
from fastapi import FastAPI, Header, HTTPException, Query, Request
from fastapi.responses import FileResponse, StreamingResponse
from pydantic import BaseModel

app = FastAPI()

ROOT_WORKSPACE = os.environ.get("CLAUDE_MODE_API_ROOT_WORKSPACE", "")
if not ROOT_WORKSPACE:
    raise RuntimeError("CLAUDE_MODE_API_ROOT_WORKSPACE is required")

API_TOKEN = os.environ.get("CLAUDE_MODE_API_TOKEN", "")
PORT = int(os.environ.get("CLAUDE_MODE_API_PORT", "8080"))

busy_workspaces: set[str] = set()


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


def _resolve_file(workspace: Optional[str], path: str) -> str:
    ws = _resolve_workspace(workspace)
    full = os.path.realpath(os.path.join(ws, path.lstrip("/")))
    if not full.startswith(os.path.realpath(ROOT_WORKSPACE)):
        raise HTTPException(status_code=400, detail="path outside root workspace")
    return full


class RunRequest(BaseModel):
    prompt: str
    workspace: Optional[str] = None
    model: Optional[str] = None
    output_format: Optional[str] = None


async def _stream(workspace: str, req: RunRequest):
    args = [
        "claude",
        "--dangerously-skip-permissions",
        "-p", req.prompt,
        "--output-format", req.output_format or "stream-json",
    ]

    if req.model:
        args += ["--model", req.model]

    env = {
        **os.environ,
        "HOME": "/home/claude",
        "CLAUDE_CONFIG_DIR": "/home/claude/.claude",
        "PATH": f"/home/claude/.claude/bin:/home/claude/.local/bin:{os.environ.get('PATH', '')}",
    }

    try:
        proc = await asyncio.create_subprocess_exec(
            *args,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.STDOUT,
            cwd=workspace,
            env=env,
        )
        if proc.stdout:
            async for line in proc.stdout:
                yield line
        await proc.wait()
    finally:
        busy_workspaces.discard(workspace)


@app.post("/run")
async def run(req: RunRequest, authorization: Optional[str] = Header(None)):
    _check_auth(authorization)

    workspace = _resolve_workspace(req.workspace)

    if not os.path.isdir(workspace):
        raise HTTPException(status_code=400, detail=f"workspace not found: {workspace}")

    if workspace in busy_workspaces:
        raise HTTPException(status_code=409, detail="workspace busy, retry later")

    busy_workspaces.add(workspace)

    return StreamingResponse(_stream(workspace, req), media_type="application/x-ndjson")


@app.get("/file")
async def get_file(
    path: str = Query(...),
    workspace: Optional[str] = Query(None),
    authorization: Optional[str] = Header(None),
):
    _check_auth(authorization)

    full = _resolve_file(workspace, path)

    if not os.path.isfile(full):
        raise HTTPException(status_code=404, detail=f"file not found: {path}")

    return FileResponse(full)


@app.put("/file")
async def put_file(
    request: Request,
    path: str = Query(...),
    workspace: Optional[str] = Query(None),
    authorization: Optional[str] = Header(None),
):
    _check_auth(authorization)

    full = _resolve_file(workspace, path)

    os.makedirs(os.path.dirname(full), exist_ok=True)

    body = await request.body()
    with open(full, "wb") as f:
        f.write(body)

    return {"status": "ok", "path": full, "size": len(body)}


@app.delete("/file")
async def delete_file(
    path: str = Query(...),
    workspace: Optional[str] = Query(None),
    authorization: Optional[str] = Header(None),
):
    _check_auth(authorization)

    full = _resolve_file(workspace, path)

    if not os.path.exists(full):
        raise HTTPException(status_code=404, detail=f"file not found: {path}")

    if os.path.isdir(full):
        raise HTTPException(status_code=400, detail="use DELETE /dir for directories")

    os.remove(full)

    return {"status": "ok", "path": full}


if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=PORT)
