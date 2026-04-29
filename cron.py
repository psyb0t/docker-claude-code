#!/usr/bin/env python3
"""Cron mode for claudebox.

Reads a yaml of jobs (cron schedule + multiline instruction) and fires
`claude -p ...` per match. Streams output to ~/.claude/cron/history/<workspace-slug>/<timestamp>-<job>/.

Activated when CLAUDEBOX_MODE_CRON=1. Yaml path from CLAUDEBOX_MODE_CRON_FILE.
Workspace from CLAUDEBOX_WORKSPACE (legacy CLAUDE_WORKSPACE still accepted).

Template variables (expanded at fire time in instruction, system_prompt, append_system_prompt):
  {system_datetime} — current UTC datetime, e.g. "2026-04-29 14:35:00 UTC"
  {job_name}        — the job's name field

Optional telegram notification: set telegram_chat_id (root or per-job) + CLAUDEBOX_TELEGRAM_BOT_TOKEN
to have Claude's result sent to a Telegram chat after each job finishes.
"""
from __future__ import annotations

import asyncio
import json
import logging
import os
import re
import shlex
import signal
import subprocess
import sys
import threading
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import yaml
from croniter import croniter

DEBUG = os.environ.get("DEBUG", "").lower() == "true"
logging.basicConfig(
    level=logging.DEBUG if DEBUG else logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
log = logging.getLogger("claudebox-cron")

CRON_FILE = os.environ.get("CLAUDEBOX_MODE_CRON_FILE") or os.environ.get("CLAUDE_MODE_CRON_FILE", "")
WORKSPACE = os.environ.get("CLAUDEBOX_WORKSPACE") or os.environ.get("CLAUDE_WORKSPACE") or "/workspace"
HOME = os.environ.get("HOME", "/home/claude")
CLAUDE_CONFIG_DIR = Path(os.environ.get("CLAUDE_CONFIG_DIR") or (Path(HOME) / ".claude"))
CRON_DIR = CLAUDE_CONFIG_DIR / "cron"
HISTORY_ROOT = CRON_DIR / "history"
TELEGRAM_MESSAGES_FILE = CRON_DIR / "telegram_messages.json"
TELEGRAM_MODE = os.environ.get("CLAUDEBOX_MODE_TELEGRAM", "") == "1"

TELEGRAM_OUTPUT_HINT = (
    "Your final result will be posted to a Telegram chat. "
    "Format using Telegram HTML: <b>bold</b>, <i>italic</i>, <u>underline</u>, "
    "<s>strikethrough</s>, <code>inline code</code>, "
    '<pre language=\"python\">code blocks</pre>, <blockquote>quotes</blockquote>. '
    "Do NOT use markdown — no *, _, `, #, - bullets. Use HTML tags only. "
    "Escape &, < and > as &amp; &lt; &gt; in regular text. "
    "Keep the response concise but readable."
)

_running_jobs: dict[str, threading.Thread] = {}
_running_lock = threading.Lock()
_shutdown = threading.Event()


def slugify(path: str) -> str:
    s = re.sub(r"[^A-Za-z0-9]+", "_", path).strip("_")
    return s or "workspace"


def _expand(text: str, fired_at: datetime, job_name: str) -> str:
    """Replace {system_datetime} and {job_name} in text."""
    return (
        text
        .replace("{system_datetime}", fired_at.strftime("%Y-%m-%d %H:%M:%S UTC"))
        .replace("{job_name}", job_name)
    )


def _validate_str_field(value: Any, label: str) -> None:
    if value is not None and not isinstance(value, str):
        raise ValueError(f"'{label}' must be a string")


_VALID_EFFORTS = {"low", "medium", "high", "xhigh", "max"}


def _validate_effort(value: Any, label: str) -> None:
    if value is None:
        return
    if not isinstance(value, str) or value not in _VALID_EFFORTS:
        raise ValueError(
            f"'{label}' must be one of {sorted(_VALID_EFFORTS)}"
        )


def load_jobs(path: str) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    log.debug("loading cron file: %s", path)
    with open(path) as f:
        data = yaml.safe_load(f) or {}
    if not isinstance(data, dict) or "jobs" not in data:
        raise ValueError("cron file must be a mapping with a 'jobs' key")

    for field in ("model", "effort", "system_prompt", "append_system_prompt"):
        _validate_str_field(data.get(field), field)
    _validate_effort(data.get("effort"), "effort")

    tg_chat = data.get("telegram_chat_id")
    if tg_chat is not None and not isinstance(tg_chat, (int, str)):
        raise ValueError("root 'telegram_chat_id' must be an int or string")

    defaults: dict[str, Any] = {
        "model": data.get("model"),
        "effort": data.get("effort"),
        "system_prompt": data.get("system_prompt"),
        "append_system_prompt": data.get("append_system_prompt"),
        "telegram_chat_id": int(tg_chat) if tg_chat is not None else None,
    }

    jobs = data["jobs"]
    if not isinstance(jobs, list) or not jobs:
        raise ValueError("'jobs' must be a non-empty list")

    seen: set[str] = set()
    valid: list[dict[str, Any]] = []
    for i, j in enumerate(jobs):
        if not isinstance(j, dict):
            raise ValueError(f"job #{i} is not a mapping")
        name = j.get("name")
        schedule = j.get("schedule")
        instruction = j.get("instruction")
        if not name or not isinstance(name, str):
            raise ValueError(f"job #{i}: 'name' is required and must be a string")
        if not re.match(r"^[A-Za-z0-9_\-]+$", name):
            raise ValueError(f"job '{name}': name must match [A-Za-z0-9_-]+")
        if name in seen:
            raise ValueError(f"duplicate job name: {name}")
        seen.add(name)
        if not schedule or not isinstance(schedule, str):
            raise ValueError(f"job '{name}': 'schedule' is required and must be a string")
        if not croniter.is_valid(schedule, second_at_beginning=True):
            raise ValueError(f"job '{name}': invalid cron schedule: {schedule}")
        if not instruction or not isinstance(instruction, str) or not instruction.strip():
            raise ValueError(f"job '{name}': 'instruction' is required and must be non-empty")
        for field in ("model", "effort", "system_prompt", "append_system_prompt"):
            _validate_str_field(j.get(field), f"job '{name}': {field}")
        _validate_effort(j.get("effort"), f"job '{name}': effort")

        job_tg = j.get("telegram_chat_id")
        if job_tg is not None and not isinstance(job_tg, (int, str)):
            raise ValueError(f"job '{name}': 'telegram_chat_id' must be an int or string")

        effective: dict[str, Any] = {
            "name": name,
            "schedule": schedule,
            "instruction": instruction,
            "model": j.get("model") or defaults["model"],
            "effort": j.get("effort") or defaults["effort"],
            "system_prompt": j.get("system_prompt") or defaults["system_prompt"],
            "append_system_prompt": j.get("append_system_prompt") or defaults["append_system_prompt"],
            "telegram_chat_id": int(job_tg) if job_tg is not None else defaults["telegram_chat_id"],
        }
        valid.append(effective)
        log.debug(
            "loaded job: name=%s schedule=%s model=%s effort=%s system_prompt=%s append_system_prompt=%s",
            name, schedule, effective["model"], effective["effort"],
            bool(effective["system_prompt"]), bool(effective["append_system_prompt"]),
        )
    return valid, defaults


def _extract_result(activity_path: Path) -> str | None:
    """Pull the result text from the last 'result' event in activity.jsonl."""
    result = None
    try:
        with open(activity_path) as f:
            for line in f:
                try:
                    ev = json.loads(line)
                    if ev.get("type") == "result" and ev.get("result"):
                        result = ev["result"]
                except json.JSONDecodeError:
                    pass
    except OSError:
        pass
    return result


def _save_telegram_message(message_id: int, job: dict[str, Any], fired_at: datetime, result: str | None) -> None:
    try:
        data: dict[str, Any] = {}
        if TELEGRAM_MESSAGES_FILE.exists():
            try:
                data = json.loads(TELEGRAM_MESSAGES_FILE.read_text())
            except Exception:
                data = {}
        data[str(message_id)] = {
            "job_name": job["name"],
            "fired_at": fired_at.isoformat(),
            "instruction": job["instruction"][:500],
            "result": (result or "")[:2000],
        }
        if len(data) > 200:
            for k in list(data.keys())[:-200]:
                del data[k]
        TELEGRAM_MESSAGES_FILE.parent.mkdir(parents=True, exist_ok=True)
        tmp = TELEGRAM_MESSAGES_FILE.with_suffix(".json.tmp")
        tmp.write_text(json.dumps(data))
        tmp.rename(TELEGRAM_MESSAGES_FILE)
    except Exception as e:
        log.warning("[%s] failed to save telegram message tracking: %s", job["name"], e)


def _notify_telegram(job: dict[str, Any], activity_path: Path, rc: int, fired_at: datetime) -> None:
    from telegram_utils import BOT_TOKEN, make_bot, send_long

    chat_id = job.get("telegram_chat_id")
    if not chat_id:
        return
    if not BOT_TOKEN:
        log.warning("[%s] telegram_chat_id set but CLAUDEBOX_TELEGRAM_BOT_TOKEN is not — skipping notify", job["name"])
        return

    result = _extract_result(activity_path)
    if result:
        text = f"<b>[{job['name']}]</b>\n{result}"
    elif rc != 0:
        text = f"<b>[{job['name']}]</b> job failed (rc={rc})"
    else:
        text = f"<b>[{job['name']}]</b> finished (no output)"

    async def _send() -> list:
        bot = make_bot()
        return await send_long(bot, chat_id, text)

    try:
        messages = asyncio.run(_send())
        log.info("[%s] telegram notification sent to %s", job["name"], chat_id)
        if TELEGRAM_MODE and messages:
            _save_telegram_message(messages[0].message_id, job, fired_at, result)
    except Exception as e:
        log.warning("[%s] telegram notify failed: %s", job["name"], e)


def _run_job(job: dict[str, Any], fired_at: datetime, workspace_slug: str) -> None:
    name = job["name"]
    ts = fired_at.strftime("%Y%m%d-%H%M%S")
    job_dir = HISTORY_ROOT / workspace_slug / f"{ts}-{name}"
    try:
        job_dir.mkdir(parents=True, exist_ok=True)
    except OSError as e:
        log.error("[%s] failed to create history dir %s: %s", name, job_dir, e)
        return

    activity_path = job_dir / "activity.jsonl"
    stderr_path = job_dir / "stderr.log"
    meta_path = job_dir / "meta.json"

    instruction = _expand(job["instruction"], fired_at, name)
    system_prompt = _expand(job["system_prompt"], fired_at, name) if job.get("system_prompt") else None
    append_system_prompt = _expand(job["append_system_prompt"], fired_at, name) if job.get("append_system_prompt") else None

    if job.get("telegram_chat_id"):
        append_system_prompt = (
            (append_system_prompt + "\n\n") if append_system_prompt else ""
        ) + TELEGRAM_OUTPUT_HINT

    cmd = ["claude", "--dangerously-skip-permissions", "-p", instruction,
           "--output-format", "stream-json", "--verbose"]
    if job.get("model"):
        cmd += ["--model", job["model"]]
    if job.get("effort"):
        cmd += ["--effort", job["effort"]]
    if system_prompt:
        cmd += ["--system-prompt", system_prompt]
    if append_system_prompt:
        cmd += ["--append-system-prompt", append_system_prompt]

    started_at = datetime.now(timezone.utc).isoformat()
    meta: dict[str, Any] = {
        "name": name,
        "schedule": job["schedule"],
        "model": job.get("model"),
        "effort": job.get("effort"),
        "instruction": instruction,
        "system_prompt": system_prompt,
        "append_system_prompt": append_system_prompt,
        "workspace": WORKSPACE,
        "started_at": started_at,
        "finished_at": None,
        "exit_code": None,
        "error": None,
    }
    meta_path.write_text(json.dumps(meta, indent=2))

    log.info("[%s] firing job (history: %s)", name, job_dir)
    log.debug("[%s] cmd: %s", name, shlex.join(cmd))

    rc = -1
    err: str | None = None
    try:
        with open(activity_path, "wb") as out_f, open(stderr_path, "wb") as err_f:
            proc = subprocess.Popen(
                cmd,
                cwd=WORKSPACE,
                stdout=subprocess.PIPE,
                stderr=err_f,
                env=os.environ.copy(),
            )
            assert proc.stdout is not None
            for line in proc.stdout:
                out_f.write(line)
                out_f.flush()
                if DEBUG:
                    try:
                        log.debug("[%s] activity: %s", name, line.decode("utf-8", errors="replace").rstrip())
                    except Exception:
                        pass
            rc = proc.wait()
    except FileNotFoundError as e:
        err = f"claude binary not found: {e}"
        log.error("[%s] %s", name, err)
    except Exception as e:
        err = f"{type(e).__name__}: {e}"
        log.exception("[%s] job crashed: %s", name, err)

    finished_at = datetime.now(timezone.utc).isoformat()
    meta["finished_at"] = finished_at
    meta["exit_code"] = rc
    meta["error"] = err
    meta_path.write_text(json.dumps(meta, indent=2))

    if rc == 0:
        log.info("[%s] finished ok (rc=0)", name)
    else:
        log.warning("[%s] finished with rc=%s err=%s", name, rc, err)

    _notify_telegram(job, activity_path, rc, fired_at)


def _spawn_job(job: dict[str, Any], fired_at: datetime, workspace_slug: str) -> None:
    name = job["name"]
    with _running_lock:
        existing = _running_jobs.get(name)
        if existing and existing.is_alive():
            log.warning("[%s] previous run still in progress — skipping this tick", name)
            return

        def target() -> None:
            try:
                _run_job(job, fired_at, workspace_slug)
            finally:
                with _running_lock:
                    if _running_jobs.get(name) is threading.current_thread():
                        del _running_jobs[name]

        t = threading.Thread(target=target, name=f"job-{name}", daemon=True)
        _running_jobs[name] = t
        t.start()


def _handle_signal(signum: int, _frame: Any) -> None:
    log.info("received signal %d, shutting down", signum)
    _shutdown.set()


def main() -> int:
    if not CRON_FILE:
        log.error("CLAUDEBOX_MODE_CRON_FILE not set")
        return 1
    if not os.path.isfile(CRON_FILE):
        log.error("cron file not found: %s", CRON_FILE)
        return 1

    try:
        jobs, defaults = load_jobs(CRON_FILE)
    except (ValueError, yaml.YAMLError) as e:
        log.error("invalid cron file: %s", e)
        return 1

    workspace_slug = slugify(WORKSPACE)
    log.info("loaded %d job(s) from %s", len(jobs), CRON_FILE)
    if defaults.get("model"):
        log.info("default model: %s", defaults["model"])
    if defaults.get("effort"):
        log.info("default effort: %s", defaults["effort"])
    if defaults.get("system_prompt"):
        log.info("default system_prompt set")
    if defaults.get("append_system_prompt"):
        log.info("default append_system_prompt set")
    if defaults.get("telegram_chat_id"):
        log.info("default telegram_chat_id: %s", defaults["telegram_chat_id"])
    log.info("workspace: %s (slug: %s)", WORKSPACE, workspace_slug)
    log.info("history root: %s", HISTORY_ROOT / workspace_slug)
    for j in jobs:
        extras = []
        if j.get("model"):
            extras.append(f"model={j['model']}")
        if j.get("effort"):
            extras.append(f"effort={j['effort']}")
        if j.get("system_prompt"):
            extras.append("system_prompt=yes")
        if j.get("append_system_prompt"):
            extras.append("append_system_prompt=yes")
        log.info("  - %s [%s]%s", j["name"], j["schedule"],
                 (" " + " ".join(extras)) if extras else "")

    HISTORY_ROOT.mkdir(parents=True, exist_ok=True)

    signal.signal(signal.SIGTERM, _handle_signal)
    signal.signal(signal.SIGINT, _handle_signal)

    now = datetime.now()
    iters = {j["name"]: croniter(j["schedule"], now, second_at_beginning=True) for j in jobs}
    next_at: dict[str, datetime] = {n: it.get_next(datetime) for n, it in iters.items()}
    for n, t in next_at.items():
        log.debug("[%s] next fire: %s", n, t.isoformat())

    while not _shutdown.is_set():
        now = datetime.now()
        for j in jobs:
            n = j["name"]
            if next_at[n] <= now:
                fired_at = next_at[n]
                _spawn_job(j, fired_at, workspace_slug)
                next_at[n] = iters[n].get_next(datetime)
                log.debug("[%s] next fire: %s", n, next_at[n].isoformat())
        soonest = min(next_at.values())
        delta = max(0.5, min(5.0, (soonest - datetime.now()).total_seconds()))
        _shutdown.wait(timeout=delta)

    log.info("waiting for in-flight jobs to finish...")
    with _running_lock:
        threads = list(_running_jobs.values())
    for t in threads:
        t.join(timeout=30)
    log.info("bye")
    return 0


if __name__ == "__main__":
    sys.exit(main())
