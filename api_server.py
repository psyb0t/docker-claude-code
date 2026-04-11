#!/usr/bin/env python3

import asyncio
import json
import logging
import os
import signal
import time
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


@asynccontextmanager
async def _lifespan(app):
    if _mcp_lifespan_cm:
        async with _mcp_lifespan_cm:
            yield
    else:
        yield


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

API_TOKEN = os.environ.get("CLAUDE_MODE_API_TOKEN", "")
try:
    PORT = int(os.environ.get("CLAUDE_MODE_API_PORT", "8080"))
except ValueError:
    log.error("CLAUDE_MODE_API_PORT must be a number, got: %s", os.environ.get("CLAUDE_MODE_API_PORT"))
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


@app.post("/run")
async def run(
    request: Request,
    req: RunRequest,
    authorization: Optional[str] = Header(None),
):
    _check_auth(authorization)

    workspace = _resolve_workspace(req.workspace)
    log.info("POST /run workspace=%s model=%s format=%s no_continue=%s",
             workspace, req.model, req.output_format, req.no_continue)

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
        from jsonpipe import _assemble

        assembled = _assemble(output.decode().splitlines())
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
        "busyWorkspaces": list(busy_workspaces.keys()),
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


# ── OpenAI-compatible adapter ─────────────────────────────────────────────────


class _OAIMessage(BaseModel):
    role: str
    content: Union[str, list[Any]]


class _OAIRequest(BaseModel):
    model_config = ConfigDict(extra="ignore")

    model: str = "claude"
    messages: list[_OAIMessage]
    stream: bool = False
    max_tokens: Optional[int] = None
    temperature: Optional[float] = None
    reasoning_effort: Optional[str] = Field(None, alias="reasoningEffort")


_OAI_MODELS = [
    {"id": "haiku", "object": "model", "created": 0, "owned_by": "anthropic"},
    {"id": "sonnet", "object": "model", "created": 0, "owned_by": "anthropic"},
    {"id": "opus", "object": "model", "created": 0, "owned_by": "anthropic"},
]


import base64  # noqa: E402
import mimetypes  # noqa: E402

_OAI_UPLOAD_DIR = os.path.join(ROOT_WORKSPACE, "_oai_uploads")
_oai_upload_counter = 0


import urllib.request  # noqa: E402


def _save_oai_image(url: str) -> Optional[str]:
    """Save an image from a data: URL, raw base64, or HTTP(S) URL to the workspace."""
    global _oai_upload_counter
    os.makedirs(_OAI_UPLOAD_DIR, exist_ok=True)

    if url.startswith("data:"):
        header, _, b64 = url.partition(",")
        mime = header.split(";")[0].replace("data:", "")
        try:
            raw = base64.b64decode(b64)
        except Exception:
            log.warning("failed to decode base64 image data")
            return None
        ext = mimetypes.guess_extension(mime) or ".bin"
        _oai_upload_counter += 1
        fname = f"upload_{_oai_upload_counter}{ext}"
        fpath = os.path.join(_OAI_UPLOAD_DIR, fname)
        with open(fpath, "wb") as f:
            f.write(raw)
        log.info("saved base64 image: %s (%d bytes, %s)", fname, len(raw), mime)
        return f"_oai_uploads/{fname}"

    if url.startswith(("http://", "https://")):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "claudebox-api"})
            with urllib.request.urlopen(req, timeout=30) as resp:
                content_type = resp.headers.get("Content-Type", "application/octet-stream")
                mime = content_type.split(";")[0].strip()
                raw = resp.read(50 * 1024 * 1024)  # 50MB max
        except Exception:
            log.warning("failed to download image from %s", url[:200])
            return None
        ext = mimetypes.guess_extension(mime) or os.path.splitext(url.split("?")[0])[1] or ".bin"
        _oai_upload_counter += 1
        fname = f"upload_{_oai_upload_counter}{ext}"
        fpath = os.path.join(_OAI_UPLOAD_DIR, fname)
        with open(fpath, "wb") as f:
            f.write(raw)
        log.info("downloaded image: %s (%d bytes, %s)", fname, len(raw), mime)
        return f"_oai_uploads/{fname}"

    # raw base64 fallback
    try:
        raw = base64.b64decode(url)
    except Exception:
        log.warning("failed to decode raw base64 content")
        return None
    _oai_upload_counter += 1
    fname = f"upload_{_oai_upload_counter}.bin"
    fpath = os.path.join(_OAI_UPLOAD_DIR, fname)
    with open(fpath, "wb") as f:
        f.write(raw)
    return f"_oai_uploads/{fname}"


def _oai_resolve_content(content: Union[str, list[Any]]) -> Union[str, list[Any]]:
    """Resolve multimodal content: download/decode images, replace URLs with local paths."""
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
            saved = _save_oai_image(url)
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


def _oai_messages_to_claude(messages: list[_OAIMessage]) -> tuple[str, Optional[str]]:
    system_parts: list[str] = []
    conv: list[dict] = []
    for msg in messages:
        if msg.role == "system":
            system_parts.append(_oai_content_text_only(msg.content))
            continue
        conv.append({"role": msg.role, "content": _oai_resolve_content(msg.content)})

    system_prompt = "\n".join(system_parts) if system_parts else None
    if not conv:
        return "", system_prompt

    # single user message with simple text — just use it directly as the prompt
    if len(conv) == 1 and isinstance(conv[0]["content"], str):
        log.debug("openai: single text message, using direct prompt")
        return conv[0]["content"], system_prompt

    # multi-turn or multimodal — write conversation to file, prompt claude to read it
    os.makedirs(_OAI_UPLOAD_DIR, exist_ok=True)
    conv_file = f"_oai_uploads/conv_{uuid.uuid4().hex[:8]}.json"
    conv_path = os.path.join(ROOT_WORKSPACE, conv_file)
    with open(conv_path, "w") as f:
        json.dump(conv, f, indent=2)
    log.info("openai: multi-turn (%d msgs), wrote conversation to %s", len(conv), conv_file)
    prompt = (
        f"Read the conversation in {conv_file}. "
        "It contains a JSON array of messages with roles (user/assistant). "
        "Any file paths in [See image: ...] blocks refer to files in the workspace. "
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

    prompt, system_prompt = _oai_messages_to_claude(req.messages)
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
        return {
            "id": cid,
            "object": "chat.completion",
            "created": created,
            "model": model,
            "choices": [
                {
                    "index": 0,
                    "message": {"role": "assistant", "content": text},
                    "finish_reason": "stop",
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
        model_name = model
        finish_reason = "stop"
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

            def _chunk(delta: dict, fr=None) -> str:
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
                        m = msg.get("model")
                        if m:
                            model_name = m
                        for block in msg.get("content", []):
                            if block.get("type") == "text":
                                text = block.get("text", "")
                                if text:
                                    yield _chunk({"content": text})
                    elif etype == "result":
                        sr = event.get("stop_reason", "")
                        if sr:
                            finish_reason = sr

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
        model: Model alias to use — haiku (fast/cheap), sonnet (balanced), opus (powerful).
               Defaults to haiku.
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
