#!/usr/bin/env python3

import asyncio
import os
from typing import Optional

import uvicorn
from fastapi import FastAPI, Header, HTTPException
from fastapi.responses import StreamingResponse
from pydantic import BaseModel

app = FastAPI()

ROOT_WORKSPACE = os.environ.get("CLAUDE_MODE_API_ROOT_WORKSPACE", "")
if not ROOT_WORKSPACE:
    raise RuntimeError("CLAUDE_MODE_API_ROOT_WORKSPACE is required")

API_TOKEN = os.environ.get("CLAUDE_MODE_API_TOKEN", "")
PORT = int(os.environ.get("CLAUDE_MODE_API_PORT", "8080"))

busy_workspaces: set[str] = set()


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
    if API_TOKEN:
        if not authorization or authorization != f"Bearer {API_TOKEN}":
            raise HTTPException(status_code=401, detail="unauthorized")

    # join requested workspace under root, stripping any leading slash
    sub = req.workspace.lstrip("/") if req.workspace else ""
    workspace = os.path.join(ROOT_WORKSPACE, sub) if sub else ROOT_WORKSPACE

    # prevent path traversal outside root
    workspace = os.path.realpath(workspace)
    if not workspace.startswith(os.path.realpath(ROOT_WORKSPACE)):
        raise HTTPException(status_code=400, detail="workspace outside root")

    if not os.path.isdir(workspace):
        raise HTTPException(status_code=400, detail=f"workspace not found: {workspace}")

    if workspace in busy_workspaces:
        raise HTTPException(status_code=409, detail="workspace busy, retry later")

    busy_workspaces.add(workspace)

    return StreamingResponse(_stream(workspace, req), media_type="application/x-ndjson")


if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=PORT)
