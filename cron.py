#!/usr/bin/env python3
"""Cron mode for claudebox.

Reads a yaml of jobs (cron schedule + multiline instruction) and fires
`claude -p ...` per match. Streams output to ~/.claude/cron/history/<workspace-slug>/<timestamp>-<job>/.

Activated when CLAUDEBOX_MODE_CRON=1. Yaml path from CLAUDEBOX_MODE_CRON_FILE.
Workspace from CLAUDEBOX_WORKSPACE (legacy CLAUDE_WORKSPACE still accepted).
"""
from __future__ import annotations

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
HISTORY_ROOT = Path(HOME) / ".claude" / "cron" / "history"

_running_jobs: dict[str, threading.Thread] = {}
_running_lock = threading.Lock()
_shutdown = threading.Event()


def slugify(path: str) -> str:
    s = re.sub(r"[^A-Za-z0-9]+", "_", path).strip("_")
    return s or "workspace"


def load_jobs(path: str) -> list[dict[str, Any]]:
    log.debug("loading cron file: %s", path)
    with open(path) as f:
        data = yaml.safe_load(f) or {}
    if not isinstance(data, dict) or "jobs" not in data:
        raise ValueError("cron file must be a mapping with a 'jobs' key")
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
        model = j.get("model")
        if model is not None and not isinstance(model, str):
            raise ValueError(f"job '{name}': 'model' must be a string")
        valid.append({
            "name": name,
            "schedule": schedule,
            "instruction": instruction,
            "model": model,
        })
        log.debug("loaded job: name=%s schedule=%s model=%s", name, schedule, model)
    return valid


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

    cmd = ["claude", "--dangerously-skip-permissions", "-p", job["instruction"],
           "--output-format", "stream-json", "--verbose"]
    if job.get("model"):
        cmd += ["--model", job["model"]]

    started_at = datetime.now(timezone.utc).isoformat()
    meta: dict[str, Any] = {
        "name": name,
        "schedule": job["schedule"],
        "model": job.get("model"),
        "instruction": job["instruction"],
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
        jobs = load_jobs(CRON_FILE)
    except (ValueError, yaml.YAMLError) as e:
        log.error("invalid cron file: %s", e)
        return 1

    workspace_slug = slugify(WORKSPACE)
    log.info("loaded %d job(s) from %s", len(jobs), CRON_FILE)
    log.info("workspace: %s (slug: %s)", WORKSPACE, workspace_slug)
    log.info("history root: %s", HISTORY_ROOT / workspace_slug)
    for j in jobs:
        log.info("  - %s [%s]%s", j["name"], j["schedule"],
                 f" model={j['model']}" if j.get("model") else "")

    HISTORY_ROOT.mkdir(parents=True, exist_ok=True)

    signal.signal(signal.SIGTERM, _handle_signal)
    signal.signal(signal.SIGINT, _handle_signal)

    # initialize each job's "next fire" time from now
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
        # sleep until the next fire, capped so we react quickly to short schedules
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
