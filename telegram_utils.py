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


# Authoritative formatting hint for Claude when output is going to Telegram.
# Sourced from https://core.telegram.org/bots/api#html-style — Telegram's HTML
# parser only accepts the tags listed here; anything else (h1-h6, br, p, div,
# ul, ol, li, hr, img, table, …) is rejected and the message fails to render.
TELEGRAM_HTML_HINT = (
    "Your output will be posted to Telegram with parse_mode=HTML. "
    "Telegram accepts ONLY this exact subset of HTML — no other tags exist:\n"
    "  <b>bold</b> / <strong>bold</strong>\n"
    "  <i>italic</i> / <em>italic</em>\n"
    "  <u>underline</u> / <ins>underline</ins>\n"
    "  <s>strike</s> / <strike>strike</strike> / <del>strike</del>\n"
    "  <tg-spoiler>spoiler</tg-spoiler> or <span class=\"tg-spoiler\">spoiler</span>\n"
    "  <a href=\"https://example.com\">link text</a>\n"
    "  <code>inline code</code>\n"
    "  <pre>preformatted block</pre>\n"
    "  <pre><code class=\"language-python\">code with language</code></pre>\n"
    "  <blockquote>quote</blockquote> or <blockquote expandable>collapsible quote</blockquote>\n"
    "Rules:\n"
    "  - Do NOT emit <h1>..<h6>, <p>, <div>, <br>, <hr>, <ul>, <ol>, <li>, "
    "<img>, <table>, or any tag not in the list above. Use <b> for headings; "
    "use plain newlines for line breaks; use '• ' as a bullet prefix on its own line.\n"
    "  - Do NOT use Markdown (**bold**, *italic*, `code`, ## heading, - bullet, "
    "[label](url), etc.). Use the HTML tags above instead.\n"
    "  - Escape literal &, <, > as &amp;, &lt;, &gt; in regular text. Inside "
    "<code> and <pre> the same escaping applies.\n"
    "  - Code language goes ONLY on <pre><code class=\"language-XXX\">, never "
    "as an attribute on <pre> directly.\n"
    "  - Tags can nest (<b><i>both</i></b>) but must be properly closed.\n"
    "Keep responses concise but readable."
)


def _strip_html(text: str) -> str:
    return _HTML_TAG_RE.sub("", text)


# ---------- markdown → Telegram HTML ----------
#
# Telegram only supports a strict subset of HTML tags (b, i, u, s, code, pre,
# blockquote, a, span, tg-spoiler, tg-emoji, tg-time). Any other tag is rejected
# by the Bot API. Plus all literal <, >, & must be escaped as &lt;, &gt;, &amp;.
#
# Claude (especially smaller models) loves to emit Markdown anyway. Rather than
# relying on prompt instructions, this converter post-processes the output:
# code blocks first (so their content isn't markdown-processed), then inline
# spans, then headings/quotes/links/list bullets, escaping literals along the
# way. Output is safe to send with parse_mode=HTML.

_PLACEHOLDER = "\x00CB{}\x00"


def _esc(s: str) -> str:
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def md_to_tg_html(text: str) -> str:
    """Convert Markdown-ish text to the HTML subset Telegram accepts."""
    if not text:
        return ""

    placeholders: list[str] = []

    def stash(html: str) -> str:
        placeholders.append(html)
        return _PLACEHOLDER.format(len(placeholders) - 1)

    # 1. fenced code blocks ```lang\n...\n```
    def _fence(m: re.Match) -> str:
        lang = (m.group(1) or "").strip()
        body = _esc(m.group(2))
        if lang:
            return stash(f'<pre><code class="language-{_esc(lang)}">{body}</code></pre>')
        return stash(f"<pre>{body}</pre>")

    text = re.sub(r"```([^\n`]*)\n(.*?)```", _fence, text, flags=re.DOTALL)

    # 2. inline code `...`
    text = re.sub(r"`([^`\n]+)`", lambda m: stash(f"<code>{_esc(m.group(1))}</code>"), text)

    # 3. links [text](url)
    def _link(m: re.Match) -> str:
        label = m.group(1)
        url = m.group(2).strip()
        return stash(f'<a href="{_esc(url)}">{_esc(label)}</a>')

    text = re.sub(r"\[([^\]\n]+)\]\(([^)\n]+)\)", _link, text)

    # 4. bold **...** and __...__
    text = re.sub(r"\*\*([^\*\n]+?)\*\*", lambda m: stash(f"<b>{_esc(m.group(1))}</b>"), text)
    text = re.sub(r"(?<!_)__([^_\n]+?)__(?!_)", lambda m: stash(f"<b>{_esc(m.group(1))}</b>"), text)

    # 5. italic *...* and _..._
    #    avoid matching ** (already handled), and bare * / _ in the middle of words
    text = re.sub(r"(?<![\*\w])\*([^\*\n]+?)\*(?!\*)", lambda m: stash(f"<i>{_esc(m.group(1))}</i>"), text)
    text = re.sub(r"(?<![_\w])_([^_\n]+?)_(?!_)", lambda m: stash(f"<i>{_esc(m.group(1))}</i>"), text)

    # 6. strikethrough ~~...~~
    text = re.sub(r"~~([^~\n]+?)~~", lambda m: stash(f"<s>{_esc(m.group(1))}</s>"), text)

    # 7. headings — Telegram has no h1-h6, render as bold on its own line
    text = re.sub(
        r"(?m)^[ \t]{0,3}(#{1,6})[ \t]+(.+?)[ \t]*#*[ \t]*$",
        lambda m: stash(f"<b>{_esc(m.group(2))}</b>"),
        text,
    )

    # 8. blockquotes — group consecutive "> " lines into one <blockquote>
    def _blockquote(m: re.Match) -> str:
        lines = [re.sub(r"^[ \t]{0,3}>[ \t]?", "", ln) for ln in m.group(0).splitlines()]
        body = _esc("\n".join(lines))
        return stash(f"<blockquote>{body}</blockquote>")

    text = re.sub(r"(?m)(^[ \t]{0,3}>[^\n]*(?:\n[ \t]{0,3}>[^\n]*)*)", _blockquote, text)

    # 9. list bullets — Telegram has no <ul>/<li>, keep readable plain text
    #    "- item" / "* item" / "+ item"  →  "• item"
    text = re.sub(r"(?m)^([ \t]*)[-*+][ \t]+", lambda m: f"{m.group(1)}• ", text)

    # 10. now escape everything that is left (literal text only — placeholders
    #     are still raw \x00CB{n}\x00 sentinels, untouched by escaping)
    text = _esc(text)

    # 11. restore placeholders with their pre-built (already-escaped) HTML
    def _restore(m: re.Match) -> str:
        return placeholders[int(m.group(1))]

    text = re.sub(r"\x00CB(\d+)\x00", _restore, text)

    return text


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
