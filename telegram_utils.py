"""Shared telegram helpers used by telegram_bot.py and cron.py."""
from __future__ import annotations

import logging
import os
import re

from telegram import Bot
from telegram.constants import MessageLimit

logger = logging.getLogger(__name__)

BOT_TOKEN = os.environ.get("CLAUDEBOX_TELEGRAM_BOT_TOKEN") or os.environ.get("CLAUDE_TELEGRAM_BOT_TOKEN", "")

_HTML_TAG_RE = re.compile(r"<[^>]+>")


def _strip_html(text: str) -> str:
    return _HTML_TAG_RE.sub("", text)


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
        except Exception as e:
            logger.warning("send_message with parse_mode=%s failed (%s), retrying as plain text", parse_mode, e)
            plain = _strip_html(chunk) if parse_mode == "HTML" else chunk
            msg = await bot.send_message(chat_id=chat_id, text=plain)
        sent.append(msg)
        text = text[len(chunk):].lstrip("\n")
        if not text:
            break
    return sent
