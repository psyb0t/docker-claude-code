#!/usr/bin/env python3

import asyncio
import json
import logging
import mimetypes
import os
import re
import sys
from pathlib import Path
from typing import Optional

import yaml
from telegram import InlineKeyboardButton, InlineKeyboardMarkup, InputFile, Update
from telegram.constants import ChatAction, MessageLimit

from telegram_utils import BOT_TOKEN, TELEGRAM_HTML_HINT, md_to_tg_html, send_long as _send_long_util

from telegram.ext import (  # isort: skip
    Application,
    CallbackQueryHandler,
    CommandHandler,
    ContextTypes,
    MessageHandler,
    filters,
)

logger = logging.getLogger(__name__)

AVAILABLE_MODELS = ["haiku", "sonnet", "opus", "opusplan"]
AVAILABLE_EFFORTS = ["low", "medium", "high", "xhigh", "max"]
RESET_TOKENS = {"__reset__", "default", "reset", "clear", "none"}
OVERRIDES_FILE = Path("/home/claude/.claude/telegram_overrides.json")
chat_overrides: dict[int, dict] = {}


def _load_overrides() -> None:
    global chat_overrides
    try:
        if OVERRIDES_FILE.exists():
            data = json.loads(OVERRIDES_FILE.read_text())
            chat_overrides = {int(k): v for k, v in data.items()}
    except Exception as e:
        logger.warning("failed to load overrides: %s", e)
        chat_overrides = {}


def _save_overrides() -> None:
    try:
        OVERRIDES_FILE.parent.mkdir(parents=True, exist_ok=True)
        tmp = OVERRIDES_FILE.with_suffix(".json.tmp")
        tmp.write_text(json.dumps({str(k): v for k, v in chat_overrides.items()}))
        tmp.rename(OVERRIDES_FILE)
    except Exception as e:
        logger.warning("failed to save overrides: %s", e)


# BOT_TOKEN imported from telegram_utils
CONFIG_PATH = (
    os.environ.get("CLAUDEBOX_TELEGRAM_CONFIG")
    or os.environ.get("CLAUDE_TELEGRAM_CONFIG")
    or "/home/claude/.claude/telegram.yml"
)
ROOT_WORKSPACE = "/workspaces"
CLAUDE_MD_TEMPLATE = "/home/claude/.claude/CLAUDE.md.template"
SYSTEM_HINT_FILE = "/home/claude/.claude/system-hint.txt"
SYSTEM_HINT = ""
if os.path.isfile(SYSTEM_HINT_FILE):
    with open(SYSTEM_HINT_FILE) as _f:
        SYSTEM_HINT = _f.read().strip()

_HOME = os.environ.get("HOME", "/home/claude")
_CLAUDE_CONFIG_DIR = Path(os.environ.get("CLAUDE_CONFIG_DIR") or (Path(_HOME) / ".claude"))
IS_CRON_MODE = os.environ.get("CLAUDEBOX_MODE_CRON", "") == "1"
CRON_FILE_PATH = os.environ.get("CLAUDEBOX_MODE_CRON_FILE", "")
CRON_MESSAGES_FILE = _CLAUDE_CONFIG_DIR / "cron" / "telegram_messages.json"


def _slugify(path: str) -> str:
    s = re.sub(r"[^A-Za-z0-9]+", "_", path).strip("_")
    return s or "workspace"


_CRON_WORKSPACE = os.environ.get("CLAUDEBOX_WORKSPACE", "/workspace")
_CRON_HISTORY_ROOT = str(_CLAUDE_CONFIG_DIR / "cron" / "history" / _slugify(_CRON_WORKSPACE))

CRON_SYSTEM_HINT = ""
if IS_CRON_MODE and CRON_FILE_PATH:
    CRON_SYSTEM_HINT = (
        f"You are running alongside a cron scheduler. "
        f"The cron configuration is at {CRON_FILE_PATH!r}. "
        f"Cron job run history is stored at {_CRON_HISTORY_ROOT!r} — "
        "each run directory contains activity.jsonl (full Claude stream output), "
        "stderr.log, and meta.json (job name, schedule, instruction, exit code, timestamps). "
        "When the user refers to something you have no context on, check the most recent "
        "run directory for the relevant job before responding."
    )

busy_chats: dict[int, Optional[asyncio.subprocess.Process]] = {}
config: dict = {}


def _ensure_workspace(path: str) -> None:
    """Create workspace dir and seed CLAUDE.md from template if missing."""
    os.makedirs(path, exist_ok=True)
    claude_md = os.path.join(path, "CLAUDE.md")
    if not os.path.isfile(claude_md) and os.path.isfile(CLAUDE_MD_TEMPLATE):
        import shutil

        shutil.copy2(CLAUDE_MD_TEMPLATE, claude_md)


def load_config() -> dict:
    if not os.path.isfile(CONFIG_PATH):
        print(f"config not found: {CONFIG_PATH}", file=sys.stderr)
        sys.exit(1)
    with open(CONFIG_PATH) as f:
        cfg = yaml.safe_load(f) or {}
    return {
        "allowed_chats": cfg.get("allowed_chats", []),
        "default": cfg.get("default", {}),
        "chats": {int(k): v for k, v in cfg.get("chats", {}).items()},
    }


def is_allowed(chat_id: int, user_id: int) -> bool:
    allowed_chats = config.get("allowed_chats", [])
    if allowed_chats and chat_id not in allowed_chats:
        return False
    # per-chat allowed_users (for groups)
    chat_cfg = config.get("chats", {}).get(chat_id, {})
    allowed_users = chat_cfg.get("allowed_users", [])
    if allowed_users and user_id not in allowed_users:
        return False
    return True


def get_chat_config(chat_id: int) -> dict:
    defaults = config.get("default", {})
    chat_cfg = config.get("chats", {}).get(chat_id, {})
    overrides = chat_overrides.get(chat_id, {})
    merged = {**defaults, **chat_cfg, **overrides}
    if "workspace" not in merged:
        merged["workspace"] = f"chat_{abs(chat_id)}"
    return merged


def _resolve_workspace(chat_cfg: dict) -> str:
    sub = chat_cfg["workspace"].lstrip("/")
    resolved = os.path.realpath(os.path.join(ROOT_WORKSPACE, sub))
    if not resolved.startswith(os.path.realpath(ROOT_WORKSPACE)):
        raise ValueError("workspace path outside root")
    return resolved


TELEGRAM_SYSTEM_HINT = (
    TELEGRAM_HTML_HINT
    + "\n\nFile attachments: when the user asks you to send/share a file, image, "
    "or video, include [SEND_FILE: relative/path] anywhere in your response and "
    "it will be delivered as a Telegram attachment (image as photo, video as "
    "video, otherwise as document). Multiple tags are allowed. The tag itself "
    "is stripped from the visible message before delivery."
)


def _load_cron_message(message_id: int) -> Optional[dict]:
    try:
        if not CRON_MESSAGES_FILE.exists():
            return None
        data = json.loads(CRON_MESSAGES_FILE.read_text())
        return data.get(str(message_id))
    except Exception:
        return None


def _build_cron_context_block(limit: int = 10) -> str:
    """Format the most recent cron runs (job, when, instruction, result) as a system-prompt block."""
    try:
        if not CRON_MESSAGES_FILE.exists():
            return ""
        data = json.loads(CRON_MESSAGES_FILE.read_text())
    except Exception:
        return ""
    runs = list(data.values())[-limit:]
    if not runs:
        return ""
    lines = [f"Recent cron job runs (most recent {len(runs)}, oldest first):"]
    for r in runs:
        instr = (r.get("instruction") or "").strip().replace("\n", " ")[:200]
        result = (r.get("result") or "").strip().replace("\n", " ")[:400]
        lines.append(
            f"- [{r.get('fired_at', '?')}] job={r.get('job_name', '?')} "
            f"instruction={instr!r} result={result!r}"
        )
    return "\n".join(lines)


def _build_claude_args(prompt: str, chat_cfg: dict, use_continue: bool = True) -> list[str]:
    args = ["claude", "--dangerously-skip-permissions"]
    if use_continue and chat_cfg.get("continue", True):
        args.append("--continue")
    args += ["-p", prompt, "--output-format", "text"]
    if chat_cfg.get("model"):
        args += ["--model", chat_cfg["model"]]
    if chat_cfg.get("system_prompt"):
        args += ["--system-prompt", chat_cfg["system_prompt"]]
    # always append: system hint + telegram hint + cron hint (if applicable) + user's append
    append_parts = []
    if SYSTEM_HINT:
        append_parts.append(SYSTEM_HINT)
    append_parts.append(TELEGRAM_SYSTEM_HINT)
    if CRON_SYSTEM_HINT:
        append_parts.append(CRON_SYSTEM_HINT)
        cron_ctx = _build_cron_context_block()
        if cron_ctx:
            append_parts.append(cron_ctx)
    if chat_cfg.get("append_system_prompt"):
        append_parts.append(chat_cfg["append_system_prompt"])
    args += ["--append-system-prompt", "\n".join(append_parts)]
    if chat_cfg.get("effort"):
        args += ["--effort", chat_cfg["effort"]]
    if chat_cfg.get("max_budget_usd"):
        args += ["--max-budget-usd", str(chat_cfg["max_budget_usd"])]
    return args


def _build_env() -> dict:
    return {
        **os.environ,
        "HOME": "/home/claude",
        "CLAUDE_CONFIG_DIR": "/home/claude/.claude",
        "PATH": (
            f"/home/claude/.claude/bin:/home/claude/.local/bin:"
            f"{os.environ.get('PATH', '')}"
        ),
    }


async def _send_long(bot, chat_id: int, text: str, parse_mode: str = "HTML") -> None:
    if parse_mode == "HTML":
        text = md_to_tg_html(text)
    await _send_long_util(bot, chat_id, text, parse_mode)


def _is_image(path: str) -> bool:
    mime = mimetypes.guess_type(path)[0] or ""
    return mime.startswith("image/")


def _is_video(path: str) -> bool:
    mime = mimetypes.guess_type(path)[0] or ""
    return mime.startswith("video/")


async def _send_file(bot, chat_id: int, path: str) -> None:
    if not os.path.isfile(path):
        await bot.send_message(
            chat_id=chat_id, text=f"not found: {os.path.basename(path)}"
        )
        return
    size = os.path.getsize(path)
    if size == 0:
        await bot.send_message(
            chat_id=chat_id, text=f"file is empty: {os.path.basename(path)}"
        )
        return
    if size > 50_000_000:
        await bot.send_message(
            chat_id=chat_id,
            text=f"file too large ({size} bytes): {os.path.basename(path)}",
        )
        return
    name = os.path.basename(path)
    logger.info("sending file %s (%d bytes) to chat %s", name, size, chat_id)
    try:
        with open(path, "rb") as f:
            inp = InputFile(f, filename=name)
            if _is_image(path):
                await bot.send_photo(chat_id=chat_id, photo=inp)
                return
            if _is_video(path):
                await bot.send_video(chat_id=chat_id, video=inp)
                return
            await bot.send_document(chat_id=chat_id, document=inp)
    except Exception as e:
        logger.exception("failed to send file %s", name)
        await bot.send_message(chat_id=chat_id, text=f"failed to send {name}: {e}")


_FILE_TAG_RE = re.compile(r"\[SEND_FILE:\s*(.+?)\]")


async def _extract_and_send_files(bot, chat_id: int, text: str, workspace: str) -> str:
    """Find [SEND_FILE: path] tags in output, send those files, strip tags."""
    matches = _FILE_TAG_RE.findall(text)
    for rel_path in matches:
        full = os.path.realpath(os.path.join(workspace, rel_path.strip()))
        if not full.startswith(os.path.realpath(ROOT_WORKSPACE)):
            continue
        await _send_file(bot, chat_id, full)
    return _FILE_TAG_RE.sub("", text).strip()


async def _typing_loop(bot, chat_id: int, stop: asyncio.Event) -> None:
    while not stop.is_set():
        try:
            await bot.send_chat_action(chat_id=chat_id, action=ChatAction.TYPING)
        except Exception:
            pass
        try:
            await asyncio.wait_for(stop.wait(), timeout=4)
            return
        except asyncio.TimeoutError:
            pass


async def _run_prompt(
    update: Update,
    context: ContextTypes.DEFAULT_TYPE,
    prompt: str,
    use_continue: bool = True,
) -> None:
    chat = update.effective_chat
    if not chat:
        return

    chat_id = chat.id

    if chat_id in busy_chats:
        logger.info("chat %s busy, rejecting prompt", chat_id)
        await update.effective_message.reply_text("busy, try again later")
        return

    chat_cfg = get_chat_config(chat_id)
    workspace = _resolve_workspace(chat_cfg)
    logger.info(
        "chat %s prompt (%d chars) workspace=%s model=%s",
        chat_id,
        len(prompt),
        workspace,
        chat_cfg.get("model", "default"),
    )
    _ensure_workspace(workspace)

    busy_chats[chat_id] = None
    stop_typing = asyncio.Event()
    typing_task = asyncio.create_task(_typing_loop(context.bot, chat_id, stop_typing))

    try:
        args = _build_claude_args(prompt, chat_cfg, use_continue=use_continue)
        env = _build_env()

        proc = await asyncio.create_subprocess_exec(
            *args,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.STDOUT,
            cwd=workspace,
            env=env,
        )
        busy_chats[chat_id] = proc
        stdout, _ = await proc.communicate()
        output = stdout.decode().strip() if stdout else ""

        # if cancelled, bail out
        if chat_id not in busy_chats:
            logger.info("chat %s cancelled, aborting", chat_id)
            stop_typing.set()
            await typing_task
            return

        # fallback: if --continue failed with no output, retry without
        if proc.returncode != 0 and not output and use_continue and chat_cfg.get("continue", True):
            logger.info(
                "chat %s --continue failed (exit=%s), retrying without",
                chat_id,
                proc.returncode,
            )
            args_retry = [a for a in args if a != "--continue"]
            proc = await asyncio.create_subprocess_exec(
                *args_retry,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.STDOUT,
                cwd=workspace,
                env=env,
            )
            busy_chats[chat_id] = proc
            stdout, _ = await proc.communicate()
            output = stdout.decode().strip() if stdout else ""

        # cancelled during retry
        if chat_id not in busy_chats:
            logger.info("chat %s cancelled during retry, aborting", chat_id)
            stop_typing.set()
            await typing_task
            return

        if not output:
            output = f"claude exited with code {proc.returncode} and no output"

        logger.info(
            "chat %s claude done, exit=%s output=%d chars",
            chat_id,
            proc.returncode,
            len(output),
        )

        stop_typing.set()
        await typing_task

        # extract [SEND_FILE: path] tags and send those files
        output = await _extract_and_send_files(context.bot, chat_id, output, workspace)
        if output:
            await _send_long(context.bot, chat_id, output)
    except Exception as e:
        stop_typing.set()
        await typing_task
        logger.exception("error running claude for chat %s", chat_id)
        await update.effective_message.reply_text(f"error: {e}")
    finally:
        busy_chats.pop(chat_id, None)


async def handle_message(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    user = update.effective_user
    chat = update.effective_chat
    if not user or not chat or not is_allowed(chat.id, user.id):
        return

    msg = update.effective_message
    text = msg.text if msg else None
    if not text:
        return

    prompt = text
    is_cron_reply = False
    if msg and msg.reply_to_message:
        replied = msg.reply_to_message
        cron_entry = (
            _load_cron_message(replied.message_id) if IS_CRON_MODE else None
        )
        if cron_entry:
            history_dir = cron_entry.get("history_dir")
            history_block = ""
            if history_dir:
                history_block = (
                    f"Full run history is on disk at {history_dir!r}. "
                    f"That directory contains activity.jsonl (full Claude stream output), "
                    f"stderr.log, meta.json (job metadata), and telegram.json "
                    f"(chat_id + message_id of the notification). "
                    f"Read those files with the Read tool if you need more context "
                    f"than the truncated summary below.\n"
                )
            prompt = (
                f"[Replying to cron job <b>{cron_entry['job_name']}</b> "
                f"that ran at {cron_entry['fired_at']}]\n"
                f"{history_block}"
                f"Job instruction (truncated): {cron_entry['instruction']}\n"
                f"Job result (truncated): {cron_entry['result']}\n\n"
                f"User follow-up: {text}"
            )
            is_cron_reply = True
            logger.info(
                "chat %s reply to cron job %s history_dir=%s (no-continue)",
                chat.id,
                cron_entry["job_name"],
                history_dir,
            )
        else:
            quoted = replied.text or replied.caption or ""
            author = (
                "the bot (you)"
                if replied.from_user and replied.from_user.is_bot
                else "the user themselves"
            )
            kind_bits = []
            if replied.photo:
                kind_bits.append("photo")
            if replied.video:
                kind_bits.append("video")
            if replied.document:
                kind_bits.append(f"document ({replied.document.file_name or 'unnamed'})")
            if replied.sticker:
                kind_bits.append(
                    f"sticker ({replied.sticker.emoji or ''} from set {replied.sticker.set_name or '?'})"
                )
            if replied.voice:
                kind_bits.append("voice message")
            if replied.audio:
                kind_bits.append("audio")
            if replied.animation:
                kind_bits.append("animation/gif")
            kind = ", ".join(kind_bits) if kind_bits else ("text" if quoted else "non-text")
            quoted_block = f"Quoted text:\n{quoted}\n" if quoted else "(no text content in the quoted message)\n"
            prompt = (
                f"[The user is replying to an earlier message (id={replied.message_id}) from {author}]\n"
                f"Quoted message kind: {kind}\n"
                f"{quoted_block}\n"
                f"User follow-up: {text}"
            )
            logger.info(
                "chat %s reply to message %s kind=%s",
                chat.id,
                replied.message_id,
                kind,
            )

    await _run_prompt(update, context, prompt, use_continue=not is_cron_reply)


async def _handle_file_upload(
    update: Update, context: ContextTypes.DEFAULT_TYPE, tg_file_obj, file_name: str
) -> None:
    user = update.effective_user
    chat = update.effective_chat
    msg = update.effective_message
    if not user or not chat or not msg:
        return

    if not is_allowed(chat.id, user.id):
        return

    chat_cfg = get_chat_config(chat.id)
    workspace = _resolve_workspace(chat_cfg)
    _ensure_workspace(workspace)

    tg_file = await tg_file_obj.get_file()
    safe_name = os.path.basename(file_name)
    dest = os.path.join(workspace, safe_name)
    await tg_file.download_to_drive(dest)
    logger.info("chat %s uploaded %s to %s", chat.id, safe_name, dest)

    caption = msg.caption or ""
    if not caption:
        await msg.reply_text(f"saved {safe_name}")
        return

    prompt = f"I saved a file '{safe_name}' to the workspace. {caption}"
    await _run_prompt(update, context, prompt)


async def handle_document(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    msg = update.effective_message
    if not msg or not msg.document:
        return
    doc = msg.document
    file_name = doc.file_name or f"file_{doc.file_unique_id}"
    await _handle_file_upload(update, context, doc, file_name)


async def handle_photo(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    msg = update.effective_message
    if not msg or not msg.photo:
        return
    # telegram sends multiple sizes, grab the largest
    photo = msg.photo[-1]
    file_name = f"photo_{photo.file_unique_id}.jpg"
    await _handle_file_upload(update, context, photo, file_name)


async def handle_video(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    msg = update.effective_message
    if not msg or not msg.video:
        return
    video = msg.video
    file_name = video.file_name or f"video_{video.file_unique_id}.mp4"
    await _handle_file_upload(update, context, video, file_name)


async def handle_voice(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    msg = update.effective_message
    if not msg or not msg.voice:
        return
    voice = msg.voice
    file_name = f"voice_{voice.file_unique_id}.ogg"
    await _handle_file_upload(update, context, voice, file_name)


async def cmd_start(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    await update.effective_message.reply_text("claude bot ready")


async def cmd_status(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    user = update.effective_user
    chat = update.effective_chat
    if not user or not chat or not is_allowed(chat.id, user.id):
        return

    if not busy_chats:
        await update.effective_message.reply_text("all clear")
        return

    lines = ["busy chats:"] + [f"  {cid}" for cid in busy_chats]
    await update.effective_message.reply_text("\n".join(lines))


async def cmd_cancel(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    user = update.effective_user
    chat = update.effective_chat
    if not user or not chat or not is_allowed(chat.id, user.id):
        return

    proc = busy_chats.get(chat.id)
    if not proc:
        await update.effective_message.reply_text("nothing running")
        return

    proc.kill()
    await proc.wait()
    busy_chats.pop(chat.id, None)
    logger.info("chat %s /cancel killed process", chat.id)
    await update.effective_message.reply_text("cancelled")


async def cmd_reload(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    user = update.effective_user
    chat = update.effective_chat
    if not user or not chat or not is_allowed(chat.id, user.id):
        return

    global config
    config = load_config()
    logger.info("chat %s /reload config reloaded", chat.id)
    await update.effective_message.reply_text("config reloaded")


async def cmd_config(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    user = update.effective_user
    chat = update.effective_chat
    if not user or not chat or not is_allowed(chat.id, user.id):
        return

    chat_cfg = get_chat_config(chat.id)
    lines = [f"chat {chat.id}:"]
    for k, v in sorted(chat_cfg.items()):
        lines.append(f"  {k}: {v}")
    await update.effective_message.reply_text("\n".join(lines))


def _resolved_value(chat_id: int, key: str, default: str = "default") -> str:
    cfg = get_chat_config(chat_id)
    val = cfg.get(key)
    return str(val) if val else default


def _set_override(chat_id: int, key: str, value) -> None:
    chat_overrides.setdefault(chat_id, {})[key] = value
    _save_overrides()


def _clear_override(chat_id: int, key: str) -> None:
    if chat_id not in chat_overrides:
        return
    chat_overrides[chat_id].pop(key, None)
    if not chat_overrides[chat_id]:
        chat_overrides.pop(chat_id, None)
    _save_overrides()


def _apply_choice(chat_id: int, key: str, choice: str, allowed: list[str]) -> None:
    if choice in RESET_TOKENS:
        _clear_override(chat_id, key)
        return
    if choice not in allowed:
        raise ValueError(f"unknown {key} {choice!r} (allowed: {allowed})")
    _set_override(chat_id, key, choice)


async def _send_choice_keyboard(
    msg, chat_id: int, key: str, label: str, options: list[str]
) -> None:
    current = _resolved_value(chat_id, key)
    overridden_val = chat_overrides.get(chat_id, {}).get(key)
    buttons = [
        [InlineKeyboardButton(
            ("✓ " if overridden_val == opt else "") + opt,
            callback_data=f"{key}:{opt}",
        )]
        for opt in options
    ]
    buttons.append([InlineKeyboardButton("reset to yaml default", callback_data=f"{key}:__reset__")])
    suffix = " (overridden)" if overridden_val is not None else " (from yaml)"
    await msg.reply_text(
        f"current {label}: <b>{current}</b>{suffix}\nselect a new one:",
        reply_markup=InlineKeyboardMarkup(buttons),
        parse_mode="HTML",
    )


async def cmd_model(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    user = update.effective_user
    chat = update.effective_chat
    msg = update.effective_message
    if not user or not chat or not msg or not is_allowed(chat.id, user.id):
        return

    if context.args:
        choice = context.args[0].strip().lower()
        try:
            _apply_choice(chat.id, "model", choice, AVAILABLE_MODELS)
        except ValueError as e:
            await msg.reply_text(str(e))
            return
        await msg.reply_text(f"model: {_resolved_value(chat.id, 'model')}")
        return

    await _send_choice_keyboard(msg, chat.id, "model", "model", AVAILABLE_MODELS)


async def cmd_effort(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    user = update.effective_user
    chat = update.effective_chat
    msg = update.effective_message
    if not user or not chat or not msg or not is_allowed(chat.id, user.id):
        return

    if context.args:
        choice = context.args[0].strip().lower()
        try:
            _apply_choice(chat.id, "effort", choice, AVAILABLE_EFFORTS)
        except ValueError as e:
            await msg.reply_text(str(e))
            return
        await msg.reply_text(f"effort: {_resolved_value(chat.id, 'effort')}")
        return

    await _send_choice_keyboard(msg, chat.id, "effort", "effort", AVAILABLE_EFFORTS)


async def _cmd_text_override(
    update: Update, context: ContextTypes.DEFAULT_TYPE, key: str, label: str
) -> None:
    user = update.effective_user
    chat = update.effective_chat
    msg = update.effective_message
    if not user or not chat or not msg or not is_allowed(chat.id, user.id):
        return

    text = (msg.text or "").partition(" ")[2].strip()

    if not text:
        current = chat_overrides.get(chat.id, {}).get(key)
        yaml_val = get_chat_config(chat.id).get(key)
        if current is not None:
            await msg.reply_text(
                f"<b>{label}</b> override (chat {chat.id}):\n<pre>{current}</pre>\n"
                f"to clear: <code>/{key} reset</code>",
                parse_mode="HTML",
            )
            return
        if yaml_val:
            await msg.reply_text(
                f"<b>{label}</b> from yaml:\n<pre>{yaml_val}</pre>\n"
                f"override with: <code>/{key} &lt;text&gt;</code>",
                parse_mode="HTML",
            )
            return
        await msg.reply_text(
            f"no {label} set. usage: <code>/{key} &lt;text&gt;</code>",
            parse_mode="HTML",
        )
        return

    if text.lower() in RESET_TOKENS:
        _clear_override(chat.id, key)
        await msg.reply_text(f"{label} override cleared")
        return

    _set_override(chat.id, key, text)
    await msg.reply_text(f"{label} override saved ({len(text)} chars)")


async def cmd_system_prompt(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    await _cmd_text_override(update, context, "system_prompt", "system_prompt")


async def cmd_append_system_prompt(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    await _cmd_text_override(update, context, "append_system_prompt", "append_system_prompt")


_BUTTON_HANDLERS = {
    "model": (AVAILABLE_MODELS, "model"),
    "effort": (AVAILABLE_EFFORTS, "effort"),
}


async def on_callback(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    query = update.callback_query
    if not query or not query.data:
        return
    user = update.effective_user
    chat = update.effective_chat
    if not user or not chat or not is_allowed(chat.id, user.id):
        await query.answer("not allowed")
        return

    key, _, choice = query.data.partition(":")
    if key in _BUTTON_HANDLERS:
        allowed, label = _BUTTON_HANDLERS[key]
        try:
            _apply_choice(chat.id, key, choice, allowed)
        except ValueError as e:
            await query.answer(str(e))
            return
        new_val = _resolved_value(chat.id, key)
        await query.answer(f"{label}: {new_val}")
        try:
            await query.edit_message_text(
                f"{label} set: <b>{new_val}</b>",
                parse_mode="HTML",
            )
        except Exception:
            pass
        return

    await query.answer()


async def cmd_bash(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    user = update.effective_user
    chat = update.effective_chat
    msg = update.effective_message
    if not user or not chat or not msg or not is_allowed(chat.id, user.id):
        return

    if not context.args:
        await msg.reply_text("usage: /bash <command>")
        return

    command = msg.text.partition(" ")[2]
    chat_cfg = get_chat_config(chat.id)
    workspace = _resolve_workspace(chat_cfg)
    _ensure_workspace(workspace)
    logger.info("chat %s /bash: %s", chat.id, command)

    proc = None
    try:
        proc = await asyncio.create_subprocess_shell(
            command,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.STDOUT,
            cwd=workspace,
            env=_build_env(),
        )
        stdout, _ = await asyncio.wait_for(proc.communicate(), timeout=120)
        output = stdout.decode().strip() if stdout else ""
        if not output:
            output = f"(exit {proc.returncode})"
    except asyncio.TimeoutError:
        if proc:
            proc.kill()
        output = "command timed out (120s)"
    except Exception as e:
        output = f"error: {e}"

    await _send_long(context.bot, chat.id, output)


async def cmd_fetch(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    user = update.effective_user
    chat = update.effective_chat
    if not user or not chat or not is_allowed(chat.id, user.id):
        return

    if not context.args:
        await update.effective_message.reply_text("usage: /fetch <path>")
        return

    rel_path = " ".join(context.args)
    logger.info("chat %s /fetch %s", chat.id, rel_path)
    chat_cfg = get_chat_config(chat.id)
    workspace = _resolve_workspace(chat_cfg)
    full = os.path.realpath(os.path.join(workspace, rel_path))
    if not full.startswith(os.path.realpath(ROOT_WORKSPACE)):
        await update.effective_message.reply_text("path outside workspace")
        return

    if not os.path.isfile(full):
        await update.effective_message.reply_text(f"not found: {rel_path}")
        return

    await _send_file(context.bot, chat.id, full)


def main() -> None:
    if not BOT_TOKEN:
        print("CLAUDEBOX_TELEGRAM_BOT_TOKEN not set", file=sys.stderr)
        sys.exit(1)

    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(name)s %(levelname)s %(message)s",
    )
    # silence httpx polling spam
    logging.getLogger("httpx").setLevel(logging.WARNING)

    global config
    config = load_config()
    _load_overrides()

    async def _post_init(application: Application) -> None:
        from telegram import BotCommand

        await application.bot.set_my_commands(
            [
                BotCommand("model", "Select claude model (overrides yaml)"),
                BotCommand("effort", "Select effort level (overrides yaml)"),
                BotCommand("system_prompt", "Set/show/reset system prompt override"),
                BotCommand("append_system_prompt", "Set/show/reset append-system-prompt override"),
                BotCommand("bash", "Run a shell command"),
                BotCommand("fetch", "Download a file from workspace"),
                BotCommand("cancel", "Kill running claude process"),
                BotCommand("status", "Show busy chats"),
                BotCommand("config", "Show chat config"),
                BotCommand("reload", "Reload YAML config"),
            ]
        )

    app = (
        Application.builder()
        .token(BOT_TOKEN)
        .concurrent_updates(True)
        .post_init(_post_init)
        .build()
    )

    app.add_handler(CommandHandler("start", cmd_start))
    app.add_handler(CommandHandler("status", cmd_status))
    app.add_handler(CommandHandler("cancel", cmd_cancel))
    app.add_handler(CommandHandler("reload", cmd_reload))
    app.add_handler(CommandHandler("config", cmd_config))
    app.add_handler(CommandHandler("model", cmd_model))
    app.add_handler(CommandHandler("effort", cmd_effort))
    app.add_handler(CommandHandler("system_prompt", cmd_system_prompt))
    app.add_handler(CommandHandler("append_system_prompt", cmd_append_system_prompt))
    app.add_handler(CommandHandler("bash", cmd_bash))
    app.add_handler(CommandHandler("fetch", cmd_fetch))
    app.add_handler(CallbackQueryHandler(on_callback))
    app.add_handler(MessageHandler(filters.Document.ALL, handle_document))
    app.add_handler(MessageHandler(filters.PHOTO, handle_photo))
    app.add_handler(MessageHandler(filters.VIDEO, handle_video))
    app.add_handler(MessageHandler(filters.VOICE, handle_voice))
    app.add_handler(MessageHandler(filters.TEXT & ~filters.COMMAND, handle_message))

    logger.info("starting telegram bot")
    app.run_polling(drop_pending_updates=True)


if __name__ == "__main__":
    main()
