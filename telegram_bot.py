#!/usr/bin/env python3

import asyncio
import logging
import mimetypes
import os
import re
import sys
from typing import Optional

import yaml
from telegram import InputFile, Update
from telegram.constants import ChatAction, MessageLimit

from telegram.ext import (  # isort: skip
    Application,
    CommandHandler,
    ContextTypes,
    MessageHandler,
    filters,
)

logger = logging.getLogger(__name__)

BOT_TOKEN = os.environ.get("CLAUDE_TELEGRAM_BOT_TOKEN", "")
CONFIG_PATH = os.environ.get(
    "CLAUDE_TELEGRAM_CONFIG", "/home/claude/.claude/telegram.yml"
)
ROOT_WORKSPACE = "/workspaces"

busy_chats: dict[int, Optional[asyncio.subprocess.Process]] = {}
config: dict = {}


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
    merged = {**defaults, **chat_cfg}
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
    "You are responding via Telegram. Keep responses concise. "
    "When the user asks you to send/share a file, image, or video, "
    "include [SEND_FILE: relative/path] in your response and it will "
    "be delivered as a Telegram attachment. You can include multiple tags. "
    "The tag is stripped from the message before delivery."
)


def _build_claude_args(prompt: str, chat_cfg: dict) -> list[str]:
    args = ["claude", "--dangerously-skip-permissions"]
    if chat_cfg.get("continue", True):
        args.append("--continue")
    args += ["-p", prompt, "--output-format", "text"]
    if chat_cfg.get("model"):
        args += ["--model", chat_cfg["model"]]
    if chat_cfg.get("system_prompt"):
        args += ["--system-prompt", chat_cfg["system_prompt"]]
    # always append the telegram hint + any user append_system_prompt
    append_parts = [TELEGRAM_SYSTEM_HINT]
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


async def _send_long(bot, chat_id: int, text: str) -> None:
    max_len = MessageLimit.MAX_TEXT_LENGTH
    while text:
        if len(text) <= max_len:
            await bot.send_message(chat_id=chat_id, text=text)
            return
        split_at = text.rfind("\n", 0, max_len)
        if split_at == -1:
            split_at = max_len
        await bot.send_message(chat_id=chat_id, text=text[:split_at])
        text = text[split_at:].lstrip("\n")


def _is_image(path: str) -> bool:
    mime = mimetypes.guess_type(path)[0] or ""
    return mime.startswith("image/")


def _is_video(path: str) -> bool:
    mime = mimetypes.guess_type(path)[0] or ""
    return mime.startswith("video/")


async def _send_file(bot, chat_id: int, path: str) -> None:
    if not os.path.isfile(path):
        return
    size = os.path.getsize(path)
    if size > 50_000_000:
        await bot.send_message(chat_id=chat_id, text=f"file too large: {path}")
        return
    with open(path, "rb") as f:
        inp = InputFile(f, filename=os.path.basename(path))
        if _is_image(path):
            await bot.send_photo(chat_id=chat_id, photo=inp)
            return
        if _is_video(path):
            await bot.send_video(chat_id=chat_id, video=inp)
            return
        await bot.send_document(chat_id=chat_id, document=inp)


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
) -> None:
    chat = update.effective_chat
    if not chat:
        return

    chat_id = chat.id

    if chat_id in busy_chats:
        await update.effective_message.reply_text("busy, try again later")
        return

    chat_cfg = get_chat_config(chat_id)
    workspace = _resolve_workspace(chat_cfg)
    os.makedirs(workspace, exist_ok=True)

    busy_chats[chat_id] = None
    stop_typing = asyncio.Event()
    typing_task = asyncio.create_task(_typing_loop(context.bot, chat_id, stop_typing))

    try:
        args = _build_claude_args(prompt, chat_cfg)
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

        # fallback: if --continue failed with no output, retry without
        if proc.returncode != 0 and not output and chat_cfg.get("continue", True):
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

        if not output:
            output = f"claude exited with code {proc.returncode} and no output"

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

    text = update.effective_message.text if update.effective_message else None
    if not text:
        return

    await _run_prompt(update, context, text)


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
    os.makedirs(workspace, exist_ok=True)

    tg_file = await tg_file_obj.get_file()
    dest = os.path.join(workspace, file_name)
    await tg_file.download_to_drive(dest)

    caption = msg.caption or ""
    if not caption:
        await msg.reply_text(f"saved {file_name}")
        return

    prompt = f"I saved a file '{file_name}' to the workspace. {caption}"
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
    await update.effective_message.reply_text("cancelled")


async def cmd_reload(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    user = update.effective_user
    chat = update.effective_chat
    if not user or not chat or not is_allowed(chat.id, user.id):
        return

    global config
    config = load_config()
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
    os.makedirs(workspace, exist_ok=True)

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
        print("CLAUDE_TELEGRAM_BOT_TOKEN not set", file=sys.stderr)
        sys.exit(1)

    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(name)s %(levelname)s %(message)s",
    )

    global config
    config = load_config()

    app = Application.builder().token(BOT_TOKEN).concurrent_updates(True).build()

    app.add_handler(CommandHandler("start", cmd_start))
    app.add_handler(CommandHandler("status", cmd_status))
    app.add_handler(CommandHandler("cancel", cmd_cancel))
    app.add_handler(CommandHandler("reload", cmd_reload))
    app.add_handler(CommandHandler("config", cmd_config))
    app.add_handler(CommandHandler("bash", cmd_bash))
    app.add_handler(CommandHandler("fetch", cmd_fetch))
    app.add_handler(MessageHandler(filters.Document.ALL, handle_document))
    app.add_handler(MessageHandler(filters.PHOTO, handle_photo))
    app.add_handler(MessageHandler(filters.VIDEO, handle_video))
    app.add_handler(MessageHandler(filters.VOICE, handle_voice))
    app.add_handler(MessageHandler(filters.TEXT & ~filters.COMMAND, handle_message))

    logger.info("starting telegram bot")
    app.run_polling(drop_pending_updates=True)


if __name__ == "__main__":
    main()
