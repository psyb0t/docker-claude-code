"""Shared telegram helpers used by telegram_bot.py and cron.py."""
from __future__ import annotations

import os

from telegram import Bot
from telegram.constants import MessageLimit

BOT_TOKEN = os.environ.get("CLAUDEBOX_TELEGRAM_BOT_TOKEN") or os.environ.get("CLAUDE_TELEGRAM_BOT_TOKEN", "")


def make_bot(token: str = "") -> Bot:
    return Bot(token=token or BOT_TOKEN)


async def send_long(bot: Bot, chat_id: int, text: str, parse_mode: str = "HTML") -> list:
    """Send text to a chat, splitting into chunks at newline boundaries.

    Returns list of sent Message objects.
    """
    sent = []
    max_len = MessageLimit.MAX_TEXT_LENGTH
    while text:
        chunk = text[:max_len] if len(text) > max_len else text
        if len(text) > max_len:
            split_at = text.rfind("\n", 0, max_len)
            if split_at != -1:
                chunk = text[:split_at]
        try:
            msg = await bot.send_message(chat_id=chat_id, text=chunk, parse_mode=parse_mode)
        except Exception:
            msg = await bot.send_message(chat_id=chat_id, text=chunk)
        sent.append(msg)
        text = text[len(chunk):].lstrip("\n")
        if not text:
            break
    return sent
