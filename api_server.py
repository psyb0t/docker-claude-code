#!/usr/bin/env python3

import asyncio
import base64
import ipaddress
import json
import logging
import mimetypes
import os
import signal
import socket
import time
import urllib.parse
import urllib.request
import uuid
from contextlib import asynccontextmanager
from typing import Any, Optional, Union

import uvicorn
from fastapi import FastAPI, Header, HTTPException, Query, Request
from fastapi.responses import FileResponse, Response, StreamingResponse
from pydantic import BaseModel, ConfigDict, Field

log = logging.getLogger("api")
_debug = os.environ.get("DEBUG", "").lower() in ("1", "true", "yes")


class _JsonFormatter(logging.Formatter):
    def format(self, record):
        return json.dumps({
            "ts": self.formatTime(record, "%Y-%m-%dT%H:%M:%S"),
            "level": record.levelname,
            "logger": record.name,
            "func": record.funcName,
            "line": record.lineno,
            "file": record.filename,
            "msg": record.getMessage(),
        })


_handler = logging.StreamHandler()
_handler.setFormatter(_JsonFormatter())
logging.root.handlers = [_handler]
logging.root.setLevel(logging.DEBUG if _debug else logging.INFO)

_mcp_lifespan_cm = None

# forward declaration — populated after module-level init
_purge_task_started = False


@asynccontextmanager
async def _lifespan(app):
    global _purge_task_started
    purge_tasks: list[asyncio.Task] = []
    if not _purge_task_started:
        _purge_task_started = True
        purge_tasks.append(asyncio.create_task(_purge_stale_results()))
        purge_tasks.append(asyncio.create_task(_purge_stale_oai_uploads()))
    try:
        if _mcp_lifespan_cm:
            async with _mcp_lifespan_cm:
                yield
        else:
            yield
    finally:
        for task in purge_tasks:
            task.cancel()


app = FastAPI(lifespan=_lifespan)


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

API_TOKEN = os.environ.get("CLAUDEBOX_MODE_API_TOKEN") or os.environ.get("CLAUDE_MODE_API_TOKEN", "")
_port_raw = os.environ.get("CLAUDEBOX_MODE_API_PORT") or os.environ.get("CLAUDE_MODE_API_PORT", "8080")
try:
    PORT = int(_port_raw)
except ValueError:
    log.error("CLAUDEBOX_MODE_API_PORT must be a number, got: %s", _port_raw)
    raise SystemExit(1)

ALWAYS_SKILLS_DIR = "/home/claude/.claude/.always-skills"
ALWAYS_SKILLS = ""
ALWAYS_SKILLS_COUNT = 0
if os.path.isdir(ALWAYS_SKILLS_DIR):
    _skill_parts: list[str] = []
    for _root, _dirs, _files in os.walk(ALWAYS_SKILLS_DIR):
        _dirs.sort()
        for _fname in sorted(_files):
            if _fname == "SKILL.md":
                _fpath = os.path.join(_root, _fname)
                try:
                    with open(_fpath) as _sf:
                        _content = _sf.read().strip()
                    _skill_parts.append(f"[Skill file: {_fpath}]\n\n{_content}")
                    log.debug("always-skill loaded: %s", _fpath)
                except OSError:
                    log.warning("always-skill: failed to read %s", _fpath)
    ALWAYS_SKILLS = "\n\n".join(_skill_parts)
    ALWAYS_SKILLS_COUNT = len(_skill_parts)
    log.info("always-skills: loaded %d from %s", ALWAYS_SKILLS_COUNT, ALWAYS_SKILLS_DIR)

busy_workspaces: dict[str, asyncio.subprocess.Process] = {}

# ── async run results cache ──────────────────────────────────────────────────

_RUN_RESULT_TTL = 6 * 3600  # 6 hours


class _RunResult:
    __slots__ = ("run_id", "workspace", "status", "output", "created_at", "error")

    def __init__(self, run_id: str, workspace: str):
        self.run_id = run_id
        self.workspace = workspace
        self.status = "running"  # running | completed | failed | cancelled
        self.output: Optional[bytes] = None
        self.created_at = time.time()
        self.error: Optional[str] = None


run_results: dict[str, _RunResult] = {}  # keyed by run_id
_run_lock = asyncio.Lock()


async def _purge_stale_results():
    """Background task: purge results older than TTL."""
    while True:
        await asyncio.sleep(300)  # check every 5 min
        now = time.time()
        stale = [rid for rid, r in run_results.items() if now - r.created_at > _RUN_RESULT_TTL]
        for rid in stale:
            log.info("purging stale run result: %s", rid)
            run_results.pop(rid, None)


async def _purge_stale_oai_uploads():
    """Background task: purge openai-wrapper upload/conv files older than TTL.

    Each /openai/v1/chat/completions multi-turn or multimodal request drops a
    file under /workspaces/_oai_uploads/. Without GC the dir grows forever.
    """
    upload_dir = os.path.join(ROOT_WORKSPACE, "_oai_uploads")
    while True:
        await asyncio.sleep(3600)  # hourly
        now = time.time()
        if not os.path.isdir(upload_dir):
            continue
        try:
            entries = os.listdir(upload_dir)
        except OSError:
            continue
        for entry in entries:
            fpath = os.path.join(upload_dir, entry)
            try:
                if now - os.path.getmtime(fpath) > _OAI_UPLOAD_TTL:
                    os.remove(fpath)
                    log.info("purged stale oai upload: %s", entry)
            except OSError:
                continue


def _check_auth(authorization: Optional[str]):
    if not API_TOKEN:
        return
    if not authorization or authorization != f"Bearer {API_TOKEN}":
        log.warning("auth failed: invalid or missing token")
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
    async_mode: bool = Field(False, alias="async")


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
    # always append system hint + always-skills + any user append
    append_parts = []
    if SYSTEM_HINT:
        append_parts.append(SYSTEM_HINT)
    if ALWAYS_SKILLS:
        append_parts.append(ALWAYS_SKILLS)
        log.debug("_build_args: injecting %d always-skill(s)", ALWAYS_SKILLS_COUNT)
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


async def _run_claude_text(
    prompt: str,
    model: Optional[str] = None,
    system_prompt: Optional[str] = None,
    append_system_prompt: Optional[str] = None,
    json_schema: Optional[str] = None,
    workspace: Optional[str] = None,
    no_continue: bool = True,
    resume: Optional[str] = None,
    effort: Optional[str] = None,
) -> tuple[str, dict]:
    """Run claude with --output-format json. Returns (result_text, usage_dict)."""
    ws = _resolve_workspace(workspace)
    if ws in busy_workspaces:
        raise HTTPException(status_code=409, detail="workspace busy, retry later")
    log.debug("_run_claude_text ws=%s model=%s continue=%s", ws, model, not no_continue)
    args = ["claude", "--dangerously-skip-permissions"]
    if resume:
        args += ["--resume", resume]
    elif not no_continue:
        args.append("--continue")
    args += ["-p", prompt, "--output-format", "json"]
    if model:
        args += ["--model", model]
    if system_prompt:
        args += ["--system-prompt", system_prompt]
    append_parts = []
    if SYSTEM_HINT:
        append_parts.append(SYSTEM_HINT)
    if ALWAYS_SKILLS:
        append_parts.append(ALWAYS_SKILLS)
    if append_system_prompt:
        append_parts.append(append_system_prompt)
    if append_parts:
        args += ["--append-system-prompt", "\n".join(append_parts)]
    if json_schema:
        args += ["--json-schema", json_schema]
    if effort:
        args += ["--effort", effort]
    env = _build_env()
    output = b""
    busy_workspaces[ws] = None  # type: ignore[assignment]
    try:
        proc = await asyncio.create_subprocess_exec(
            *args,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.STDOUT,
            cwd=ws,
            env=env,
            limit=_STREAM_LIMIT,
        )
        busy_workspaces[ws] = proc
        if proc.stdout:
            async for chunk in proc.stdout:
                output += chunk
        await proc.wait()
    finally:
        busy_workspaces.pop(ws, None)
    text = output.decode(errors="replace")
    for line in reversed(text.splitlines()):
        line = line.strip()
        if not line:
            continue
        try:
            parsed = json.loads(line)
            usage = parsed.get("usage", {})
            stop_reason = parsed.get("stop_reason")
            if stop_reason:
                usage["_stop_reason"] = stop_reason
            result = parsed.get("result", text)
            log.debug("_run_claude_text done, result=%d chars", len(result))
            return result, usage
        except (json.JSONDecodeError, ValueError):
            continue
    log.warning("_run_claude_text: no JSON result found in output (%d bytes)", len(output))
    return text, {}


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


def _prepare_run(req: RunRequest) -> tuple[str, str]:
    """Validate and prepare a run request. Returns (workspace, run_id)."""
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

    run_id = uuid.uuid4().hex[:16]
    return workspace, run_id


def _finalize_output(req: RunRequest, output: bytes) -> bytes:
    """Process raw output into final response content."""
    if req.output_format == "json-verbose":
        from jsonpipe import _assemble

        assembled = _assemble(output.decode().splitlines())
        return json.dumps(assembled).encode()
    return _normalize_response(output)


async def _run_async_task(workspace: str, run_id: str, req: RunRequest):
    """Background task for async runs."""
    rr = run_results.get(run_id)
    if not rr:
        return
    output = b""
    try:
        async for chunk in _stream(workspace, req):
            output += chunk
        async with _run_lock:
            if rr.status == "cancelled":
                return
            rr.output = _finalize_output(req, output)
            rr.status = "completed"
            log.info("async run %s completed (%d bytes)", run_id, len(rr.output))
    except Exception as exc:
        async with _run_lock:
            if rr.status == "cancelled":
                return
            rr.status = "failed"
            rr.error = str(exc)
            log.error("async run %s failed: %s", run_id, exc)


@app.post("/run")
async def run(
    request: Request,
    req: RunRequest,
    authorization: Optional[str] = Header(None),
):
    _check_auth(authorization)

    workspace, run_id = _prepare_run(req)
    log.info("POST /run workspace=%s model=%s format=%s async=%s run_id=%s",
             workspace, req.model, req.output_format, req.async_mode, run_id)

    async with _run_lock:
        rr = _RunResult(run_id, workspace)
        run_results[run_id] = rr
        busy_workspaces[workspace] = None  # type: ignore[assignment]

    # async mode — kick off background task, return immediately
    if req.async_mode:
        asyncio.create_task(_run_async_task(workspace, run_id, req))
        return {"runId": run_id, "workspace": workspace, "status": "running"}

    # sync mode — block until done

    watcher = None
    if not req.fire_and_forget:

        async def _disconnect_watcher():
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
        rr.status = "failed"
        rr.error = "client disconnected"
        return Response(status_code=499)

    content = _finalize_output(req, output)
    rr.output = content
    rr.status = "completed"

    # inject runId into response JSON
    try:
        parsed = json.loads(content)
        parsed["runId"] = run_id
        parsed["workspace"] = workspace
        content = json.dumps(parsed).encode()
    except (json.JSONDecodeError, ValueError):
        pass

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

    runs = []
    for rid, rr in run_results.items():
        runs.append({"runId": rid, "workspace": rr.workspace, "status": rr.status})

    return {
        "busyWorkspaces": list(busy_workspaces.keys()),
        "runs": runs,
    }


@app.get("/run/result")
async def run_result(
    run_id: str = Query(..., alias="runId"),
    authorization: Optional[str] = Header(None),
):
    _check_auth(authorization)

    async with _run_lock:
        rr = run_results.get(run_id)
        if not rr:
            raise HTTPException(status_code=404, detail="run not found")

        if rr.status == "running":
            return {"runId": run_id, "workspace": rr.workspace, "status": "running"}

        if rr.status == "cancelled":
            run_results.pop(run_id, None)
            return {"runId": run_id, "workspace": rr.workspace, "status": "cancelled"}

        if rr.status == "failed":
            error = rr.error
            run_results.pop(run_id, None)
            return {"runId": run_id, "workspace": rr.workspace, "status": "failed", "error": error}

        # completed — return result and purge
        output = rr.output or b"{}"
        workspace = rr.workspace
        run_results.pop(run_id, None)

    log.info("delivering result for run %s (%d bytes), purging", run_id, len(output))

    try:
        parsed = json.loads(output)
        parsed["runId"] = run_id
        parsed["workspace"] = workspace
        return parsed
    except (json.JSONDecodeError, ValueError):
        return Response(content=output, media_type="application/json")


@app.post("/run/cancel")
async def cancel_run(
    workspace: Optional[str] = Query(None),
    run_id: Optional[str] = Query(None, alias="runId"),
    authorization: Optional[str] = Header(None),
):
    _check_auth(authorization)

    # cancel by runId
    if run_id:
        async with _run_lock:
            rr = run_results.get(run_id)
            if not rr:
                raise HTTPException(status_code=404, detail="run not found")
            ws = rr.workspace
            proc = busy_workspaces.get(ws)
            rr.status = "cancelled"
            busy_workspaces.pop(ws, None)
        if proc:
            proc.kill()
            await proc.wait()
        return {"status": "ok", "runId": run_id, "workspace": ws}

    # cancel by workspace (legacy)
    ws = _resolve_workspace(workspace)
    proc = busy_workspaces.get(ws)
    if not proc:
        raise HTTPException(status_code=404, detail="no running process for workspace")

    proc.kill()
    await proc.wait()

    async with _run_lock:
        for rr in run_results.values():
            if rr.workspace == ws and rr.status == "running":
                rr.status = "cancelled"

    return {"status": "ok", "workspace": ws}


# ── OpenAI-compatible adapter ─────────────────────────────────────────────────


class _OAIMessage(BaseModel):
    role: str
    content: Union[str, list[Any]]


class _OAIRequest(BaseModel):
    model_config = ConfigDict(extra="ignore", populate_by_name=True)

    model: str = "claude"
    messages: list[_OAIMessage]
    stream: bool = False
    reasoning_effort: Optional[str] = Field(None, alias="reasoningEffort")
    # explicitly captured so we can 400 instead of silently dropping
    tools: Optional[Any] = None
    tool_choice: Optional[Any] = None
    response_format: Optional[dict] = None


_OAI_MODELS = [
    {"id": "haiku", "object": "model", "created": 0, "owned_by": "anthropic"},
    {"id": "sonnet", "object": "model", "created": 0, "owned_by": "anthropic"},
    {"id": "opus", "object": "model", "created": 0, "owned_by": "anthropic"},
    {"id": "opusplan", "object": "model", "created": 0, "owned_by": "anthropic"},
]


_OAI_UPLOAD_DIR = os.path.join(ROOT_WORKSPACE, "_oai_uploads")
_OAI_UPLOAD_TTL = 24 * 3600  # 24 hours
_OAI_REMOTE_IMAGE_TIMEOUT = 30
_OAI_REMOTE_IMAGE_MAX_BYTES = 50 * 1024 * 1024  # 50MB


# claude → openai finish_reason mapping. claude emits end_turn / stop_sequence /
# max_tokens / tool_use; openai expects stop / length / tool_calls / content_filter
# / function_call. Strict openai SDKs reject unknown enums.
_OAI_FINISH_REASON_MAP = {
    "end_turn": "stop",
    "stop_sequence": "stop",
    "max_tokens": "length",
    "tool_use": "tool_calls",
}


def _map_stop_reason(claude_reason: Optional[str]) -> str:
    if not claude_reason:
        return "stop"
    return _OAI_FINISH_REASON_MAP.get(claude_reason, "stop")


def _is_safe_remote_url(url: str) -> bool:
    """SSRF guard: reject URLs that resolve to private/loopback/link-local/etc IPs.

    Defense-in-depth — does not protect against DNS rebinding (the resolver could
    return a different address on the actual urllib fetch). For the threat model
    here (untrusted user-supplied image URLs in chat-completions requests) the
    rebinding risk is acceptable; the goal is to stop trivially unsafe URLs like
    http://169.254.169.254 (cloud metadata) or http://localhost from succeeding.
    """
    try:
        parsed = urllib.parse.urlparse(url)
    except (ValueError, TypeError):
        return False
    if parsed.scheme not in ("http", "https"):
        return False
    if not parsed.hostname:
        return False
    try:
        infos = socket.getaddrinfo(parsed.hostname, None)
    except socket.gaierror:
        return False
    for info in infos:
        try:
            ip = ipaddress.ip_address(info[4][0])
        except ValueError:
            return False
        if (ip.is_private or ip.is_loopback or ip.is_link_local
                or ip.is_multicast or ip.is_reserved or ip.is_unspecified):
            return False
    return True


def _write_oai_upload(raw: bytes, ext: str) -> str:
    """Write bytes to a uniquely named file under _OAI_UPLOAD_DIR. Returns absolute path."""
    os.makedirs(_OAI_UPLOAD_DIR, exist_ok=True)
    fname = f"upload_{uuid.uuid4().hex[:12]}{ext}"
    fpath = os.path.join(_OAI_UPLOAD_DIR, fname)
    with open(fpath, "wb") as f:
        f.write(raw)
    log.info("saved oai upload: %s (%d bytes)", fname, len(raw))
    return fpath


def _save_oai_data_uri(url: str) -> Optional[str]:
    header, _, b64 = url.partition(",")
    mime = header.split(";")[0].replace("data:", "")
    try:
        raw = base64.b64decode(b64)
    except (ValueError, TypeError):
        log.warning("failed to decode data: URL")
        return None
    ext = mimetypes.guess_extension(mime) or ".bin"
    return _write_oai_upload(raw, ext)


def _fetch_oai_remote_sync(url: str) -> Optional[tuple[bytes, str]]:
    """Synchronous URL fetch (run via run_in_executor — urllib blocks). Returns (raw, mime)."""
    if not _is_safe_remote_url(url):
        log.warning("refusing to fetch image from unsafe URL: %s", url[:200])
        return None
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "claudebox-api"})
        with urllib.request.urlopen(req, timeout=_OAI_REMOTE_IMAGE_TIMEOUT) as resp:
            content_type = resp.headers.get("Content-Type", "application/octet-stream")
            raw = resp.read(_OAI_REMOTE_IMAGE_MAX_BYTES)
    except Exception:
        log.warning("failed to download image from %s", url[:200])
        return None
    return raw, content_type.split(";")[0].strip()


async def _save_oai_image(url: str) -> Optional[str]:
    """Save an image from a data: URL or HTTP(S) URL. Returns absolute path on success.

    Raw-base64 fallback was removed — too easy to abuse, and dumping arbitrary
    decoded bytes into the workspace as upload_*.bin was a footgun.
    """
    if url.startswith("data:"):
        return _save_oai_data_uri(url)
    if url.startswith(("http://", "https://")):
        result = await asyncio.get_event_loop().run_in_executor(
            None, _fetch_oai_remote_sync, url
        )
        if not result:
            return None
        raw, mime = result
        ext = (mimetypes.guess_extension(mime)
               or os.path.splitext(urllib.parse.urlparse(url).path)[1]
               or ".bin")
        return _write_oai_upload(raw, ext)
    log.warning("unsupported image URL scheme")
    return None


async def _oai_resolve_content(content: Union[str, list[Any]]) -> Union[str, list[Any]]:
    """Resolve multimodal content: download/decode images, replace URLs with absolute local paths."""
    if isinstance(content, str):
        return content
    resolved: list[Any] = []
    for block in content:
        if isinstance(block, str):
            resolved.append(block)
            continue
        if not isinstance(block, dict):
            resolved.append(block)
            continue
        if block.get("type") == "image_url":
            url = block.get("image_url", {}).get("url", "")
            if not url:
                continue
            saved = await _save_oai_image(url)
            if saved:
                resolved.append({"type": "text", "text": f"[See image: {saved}]"})
            continue
        resolved.append(block)
    return resolved


def _oai_content_text_only(content: Union[str, list[Any]]) -> str:
    """Extract just the text from content (for system prompt extraction)."""
    if isinstance(content, str):
        return content
    parts = []
    for block in content:
        if isinstance(block, str):
            parts.append(block)
        elif isinstance(block, dict) and block.get("type") == "text":
            parts.append(block.get("text", ""))
    return "\n".join(parts)


async def _oai_messages_to_claude(messages: list[_OAIMessage]) -> tuple[str, Optional[str]]:
    system_parts: list[str] = []
    conv: list[dict] = []
    for msg in messages:
        if msg.role == "system":
            system_parts.append(_oai_content_text_only(msg.content))
            continue
        conv.append({"role": msg.role, "content": await _oai_resolve_content(msg.content)})

    system_prompt = "\n".join(system_parts) if system_parts else None
    if not conv:
        return "", system_prompt

    # single user message with simple text — just use it directly as the prompt
    if len(conv) == 1 and isinstance(conv[0]["content"], str):
        log.debug("openai: single text message, using direct prompt")
        return conv[0]["content"], system_prompt

    # multi-turn or multimodal — write conversation to a file under _OAI_UPLOAD_DIR
    # and reference it by ABSOLUTE path. Earlier versions used a relative path,
    # which broke whenever workspace != ROOT_WORKSPACE because claude's cwd is
    # the requested workspace, not ROOT_WORKSPACE.
    os.makedirs(_OAI_UPLOAD_DIR, exist_ok=True)
    conv_path = os.path.join(_OAI_UPLOAD_DIR, f"conv_{uuid.uuid4().hex[:12]}.json")
    with open(conv_path, "w") as f:
        json.dump(conv, f, indent=2)
    log.info("openai: multi-turn (%d msgs), wrote conversation to %s", len(conv), conv_path)
    prompt = (
        f"Read the conversation in {conv_path}. "
        "It contains a JSON array of messages with roles (user/assistant). "
        "Any file paths in [See image: ...] blocks are absolute paths to files on disk — read them. "
        "Respond to the last user message in the conversation."
    )
    return prompt, system_prompt


def _build_oai_run_args(
    prompt: str,
    model: str,
    system_prompt: Optional[str],
    streaming: bool,
    effort: Optional[str] = None,
    no_continue: bool = True,
    append_system_prompt: Optional[str] = None,
) -> list[str]:
    args = ["claude", "--dangerously-skip-permissions"]
    if not no_continue:
        args.append("--continue")
    if streaming:
        args += ["-p", prompt, "--output-format", "stream-json", "--verbose"]
    else:
        args += ["-p", prompt, "--output-format", "json"]
    if model:
        args += ["--model", model]
    if system_prompt:
        args += ["--system-prompt", system_prompt]
    append_parts = []
    if SYSTEM_HINT:
        append_parts.append(SYSTEM_HINT)
    if ALWAYS_SKILLS:
        append_parts.append(ALWAYS_SKILLS)
    if append_system_prompt:
        append_parts.append(append_system_prompt)
    if append_parts:
        args += ["--append-system-prompt", "\n".join(append_parts)]
    if effort:
        args += ["--effort", effort]
    return args


@app.get("/openai/v1/models")
async def openai_models(authorization: Optional[str] = Header(None)):
    _check_auth(authorization)
    return {"object": "list", "data": _OAI_MODELS}


@app.post("/openai/v1/chat/completions")
async def openai_chat_completions(
    req: _OAIRequest,
    authorization: Optional[str] = Header(None),
    x_claude_workspace: Optional[str] = Header(None, alias="x-claude-workspace"),
    x_claude_continue: Optional[str] = Header(None, alias="x-claude-continue"),
    x_claude_append_system_prompt: Optional[str] = Header(None, alias="x-claude-append-system-prompt"),
):
    _check_auth(authorization)

    # Reject features the wrapper can't honor — silent drop confuses clients.
    # Anyone needing tool-calling or structured JSON should hit /run with
    # --json-schema, which is the native claude-code path.
    if req.tools or req.tool_choice:
        raise HTTPException(
            status_code=400,
            detail=(
                "tools/tool_choice not supported by this endpoint — "
                "claude-code runs its own tools internally; use /run for the native API"
            ),
        )
    if req.response_format and req.response_format.get("type") == "json_object":
        raise HTTPException(
            status_code=400,
            detail="response_format=json_object not supported — use /run with jsonSchema for structured output",
        )

    prompt, system_prompt = await _oai_messages_to_claude(req.messages)
    if not prompt:
        raise HTTPException(status_code=400, detail="no user message provided")

    # strip provider prefix (e.g. "openai/haiku" → "haiku")
    model = req.model.split("/", 1)[-1] if "/" in req.model else req.model

    no_continue = x_claude_continue is None or x_claude_continue.lower() not in ("1", "true", "yes")

    log.info("POST /openai/v1/chat/completions model=%s stream=%s msgs=%d workspace=%s continue=%s",
             model, req.stream, len(req.messages), x_claude_workspace, not no_continue)
    log.debug("openai prompt: %s", prompt[:200])

    cid = f"chatcmpl-{uuid.uuid4().hex[:12]}"
    created = int(time.time())

    if not req.stream:
        text, usage = await _run_claude_text(
            prompt,
            model=model,
            system_prompt=system_prompt,
            append_system_prompt=x_claude_append_system_prompt,
            workspace=x_claude_workspace,
            no_continue=no_continue,
            effort=req.reasoning_effort,
        )
        in_tok = usage.get("input_tokens", 0) or usage.get("inputTokens", 0)
        out_tok = usage.get("output_tokens", 0) or usage.get("outputTokens", 0)
        finish_reason = _map_stop_reason(usage.get("_stop_reason"))
        return {
            "id": cid,
            "object": "chat.completion",
            "created": created,
            "model": model,
            "choices": [
                {
                    "index": 0,
                    "message": {"role": "assistant", "content": text},
                    "finish_reason": finish_reason,
                }
            ],
            "usage": {
                "prompt_tokens": in_tok,
                "completion_tokens": out_tok,
                "total_tokens": in_tok + out_tok,
            },
        }

    workspace = _resolve_workspace(x_claude_workspace)

    if workspace in busy_workspaces:
        raise HTTPException(status_code=409, detail="workspace busy, retry later")

    args = _build_oai_run_args(
        prompt, model, system_prompt, True, req.reasoning_effort, no_continue, x_claude_append_system_prompt,
    )
    env = _build_env()

    busy_workspaces[workspace] = None  # type: ignore[assignment]

    async def _sse():
        # model_name is fixed for the entire stream — openai SDKs flag a
        # mid-stream model change as a protocol violation, so we don't update
        # this from the assistant events even though claude reports its own id.
        model_name = model
        finish_reason: Optional[str] = "stop"
        try:
            proc = await asyncio.create_subprocess_exec(
                *args,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
                cwd=workspace,
                env=env,
                limit=_STREAM_LIMIT,
            )
            busy_workspaces[workspace] = proc

            def _chunk(delta: dict, fr: Optional[str] = None) -> str:
                obj = {
                    "id": cid, "object": "chat.completion.chunk",
                    "created": created, "model": model_name,
                    "choices": [{"index": 0, "delta": delta, "finish_reason": fr}],
                }
                return f"data: {json.dumps(obj)}\n\n"

            yield _chunk({"role": "assistant", "content": ""})

            if proc.stdout:
                async for raw in proc.stdout:
                    line = raw.decode(errors="replace").strip()
                    if not line:
                        continue
                    try:
                        event = json.loads(line)
                    except json.JSONDecodeError:
                        continue
                    etype = event.get("type", "")
                    if etype == "assistant":
                        msg = event.get("message", {})
                        for block in msg.get("content", []):
                            if block.get("type") == "text":
                                text = block.get("text", "")
                                if text:
                                    yield _chunk({"content": text})
                    elif etype == "result":
                        finish_reason = _map_stop_reason(event.get("stop_reason"))

            await proc.wait()
            yield _chunk({}, finish_reason)
            yield "data: [DONE]\n\n"
        finally:
            busy_workspaces.pop(workspace, None)

    return StreamingResponse(_sse(), media_type="text/event-stream")


# ── MCP server ────────────────────────────────────────────────────────────────

from mcp.server.fastmcp import FastMCP  # noqa: E402

_mcp = FastMCP("claudebox", streamable_http_path="/")


@_mcp.tool()
async def claude_run(
    prompt: str,
    model: str = "haiku",
    system_prompt: str = "",
    append_system_prompt: str = "",
    json_schema: str = "",
    workspace: str = "",
    no_continue: bool = True,
    resume: str = "",
    effort: str = "",
) -> str:
    """Run a prompt/task through Claude Code (the agentic CLI) and return the text response.
    Claude Code can read/write files, run shell commands, execute code, and use tools
    in the workspace — it is not a simple chat model call.

    IMPORTANT — preferred workflow for best performance:
    Instead of embedding large file contents or context directly in the prompt, you should:
    1. Use write_file to upload any input files, code, or context into the workspace first.
    2. Write a short prompt that tells Claude Code to read those files and do the task.
    3. Let Claude Code write its output/results to files in the workspace.
    4. Use read_file or list_files to retrieve the output files.
    Sending large content as prompt text is slow and wastes context. File-based workflows
    are significantly faster and more reliable.

    Args:
        prompt: The prompt/task to send to Claude Code.
        model: Model alias to use — haiku (fast/cheap), sonnet (balanced), opus (powerful),
               opusplan (planning with sonnet+opus). Defaults to haiku.
        system_prompt: Override the default system prompt entirely.
        append_system_prompt: Text to append to the system prompt without replacing it.
        json_schema: JSON Schema string for structured output — Claude will return JSON
                     matching this schema.
        workspace: Subpath under /workspaces to use as the working directory
                   (e.g. "myproject" → /workspaces/myproject). Defaults to /workspaces.
        no_continue: If True (default), start a fresh session. If False, continue the
                     previous conversation in this workspace.
        resume: Resume a specific session by session ID instead of starting fresh.
        effort: Reasoning effort level — low, medium, high, or max.
    """
    log.info("MCP claude_run model=%s workspace=%s", model, workspace or "(default)")
    text, _ = await _run_claude_text(
        prompt,
        model=model or None,
        system_prompt=system_prompt or None,
        append_system_prompt=append_system_prompt or None,
        json_schema=json_schema or None,
        workspace=workspace or None,
        no_continue=no_continue,
        resume=resume or None,
        effort=effort or None,
    )
    return text


@_mcp.tool()
async def list_files(path: str = "") -> str:
    """List files and directories in the workspace.

    Args:
        path: Path relative to /workspaces to list. Defaults to the workspace root.
              Returns a JSON object with a path and entries array, each entry having
              name and type (file or dir).
    """
    full = _resolve_path(path) if path else os.path.realpath(ROOT_WORKSPACE)
    if not os.path.exists(full):
        return json.dumps({"error": f"not found: {path}"})
    if os.path.isdir(full):
        entries = []
        for name in sorted(os.listdir(full)):
            ep = os.path.join(full, name)
            entries.append({"name": name, "type": "dir" if os.path.isdir(ep) else "file"})
        return json.dumps({"path": path or "/", "entries": entries})
    return json.dumps({"error": "not a directory"})


@_mcp.tool()
async def read_file(path: str) -> str:
    """Read a file from the workspace and return its full text contents.

    Args:
        path: Path to the file relative to /workspaces (e.g. "myproject/src/main.py").
    """
    full = _resolve_path(path)
    if not os.path.isfile(full):
        return f"error: not found: {path}"
    with open(full) as f:
        return f.read()


@_mcp.tool()
async def write_file(path: str, content: str) -> str:
    """Write content to a file in the workspace. Creates parent directories if needed.

    Args:
        path: Path to the file relative to /workspaces (e.g. "myproject/src/main.py").
        content: Full text content to write. Overwrites the file if it already exists.
    """
    full = _resolve_path(path)
    os.makedirs(os.path.dirname(full), exist_ok=True)
    with open(full, "w") as f:
        f.write(content)
    return json.dumps({"status": "ok", "path": path})


@_mcp.tool()
async def delete_file(path: str) -> str:
    """Delete a file from the workspace. Only files can be deleted, not directories.

    Args:
        path: Path to the file relative to /workspaces (e.g. "myproject/old.py").
    """
    full = _resolve_path(path)
    if not os.path.exists(full):
        return json.dumps({"error": f"not found: {path}"})
    if os.path.isdir(full):
        return json.dumps({"error": "cannot delete directories"})
    os.remove(full)
    return json.dumps({"status": "ok", "path": path})


_mcp_app = _mcp.streamable_http_app()
_mcp_lifespan_cm = _mcp_app.router.lifespan_context(_mcp_app)


def _mcp_auth_check(scope) -> bool:
    if not API_TOKEN:
        return True
    headers = {k: v for k, v in scope.get("headers", [])}
    auth = headers.get(b"authorization", b"").decode()
    if auth == f"Bearer {API_TOKEN}":
        return True
    qs = scope.get("query_string", b"").decode()
    for part in qs.split("&"):
        if part.startswith("apiToken=") and part[9:] == API_TOKEN:
            return True
    return False


class _MCPWithAuth:
    """Route /mcp requests to the MCP ASGI handler with auth."""

    def __init__(self, mcp_app):
        self._app = mcp_app

    async def __call__(self, scope, receive, send):
        if scope["type"] not in ("http", "websocket"):
            await self._app(scope, receive, send)
            return
        if not _mcp_auth_check(scope):
            log.warning("MCP auth failed: invalid or missing token")
            await send({
                "type": "http.response.start",
                "status": 401,
                "headers": [[b"content-type", b"application/json"]],
            })
            await send({"type": "http.response.body", "body": b'{"detail":"unauthorized"}'})
            return
        log.debug("MCP request: %s %s", scope.get("method", "?"), scope.get("path", "?"))
        await self._app(scope, receive, send)


app.mount("/mcp", _MCPWithAuth(_mcp_app))


if __name__ == "__main__":
    log.info("starting api server on port %d (auth=%s, debug=%s)", PORT, bool(API_TOKEN), _debug)
    uvicorn.run(app, host="0.0.0.0", port=PORT)
