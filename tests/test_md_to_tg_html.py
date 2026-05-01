"""Unit tests for the Markdown -> Telegram-HTML converter.

Run with:  python -m pytest tests/test_md_to_tg_html.py  -v
or:        python tests/test_md_to_tg_html.py
"""
from __future__ import annotations

import os
import re
import sys

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))

from telegram_utils import md_to_tg_html  # noqa: E402

# Anything matching this regex in the OUTPUT is a placeholder leak.
LEAK_RE = re.compile(r"[\uE000\uE001\x00]")


def assert_clean(out: str) -> None:
    leak = LEAK_RE.search(out)
    assert leak is None, f"placeholder leak {leak.group()!r} in output: {out!r}"


def test_plain_text():
    assert md_to_tg_html("hello world") == "hello world"


def test_bold():
    out = md_to_tg_html("**hi**")
    assert_clean(out)
    assert out == "<b>hi</b>"


def test_inline_code():
    out = md_to_tg_html("use `grep` here")
    assert_clean(out)
    assert "<code>grep</code>" in out


def test_heading_with_bold_inside_is_the_real_world_leak():
    # Reproduces the v1.12.6 leak: heading body contained an already-stashed
    # bold placeholder; the single-pass restore left the inner sentinel
    # untouched, so users saw "CB2" rendered (with invisible PUA chars on
    # either side, or bare CB2 when transport stripped NUL).
    out = md_to_tg_html("## **Logs**")
    assert_clean(out)
    assert out == "<b><b>Logs</b></b>" or out == "<b>Logs</b>"


def test_full_watchdog_message():
    src = (
        "## **Logs** \n"
        "Mostly boring-ass cron jobs.\n\n"
        "## **Security**\n"
        "Clean as a whistle.\n\n"
        "## **Docker Health** \n"
        "**PROBLEM**: `mt5-httpapi-mt5-1` is **unhealthy**.\n\n"
        "## **Tunnels**\n"
        "- mt5-httpapi-cloudflared-1\n"
        "- smegma_cloudflared\n"
        "- remy-cloudflared\n\n"
        "**Bottom line**: look-see."
    )
    out = md_to_tg_html(src)
    assert_clean(out)
    # sanity: known fragments survived
    assert "Logs" in out
    assert "Security" in out
    assert "<code>mt5-httpapi-mt5-1</code>" in out
    assert "• mt5-httpapi-cloudflared-1" in out


def test_fenced_code_block():
    out = md_to_tg_html("```python\nprint('hi')\n```")
    assert_clean(out)
    assert '<pre><code class="language-python">' in out
    assert "print(&#x27;hi&#x27;)" in out or "print('hi')" in out


def test_link():
    out = md_to_tg_html("[click](https://example.com)")
    assert_clean(out)
    assert '<a href="https://example.com">click</a>' == out


def test_blockquote():
    out = md_to_tg_html("> quoted line\n> next line")
    assert_clean(out)
    assert "<blockquote>" in out


def test_strikethrough_and_italic():
    out = md_to_tg_html("~~old~~ and *new*")
    assert_clean(out)
    assert "<s>old</s>" in out
    assert "<i>new</i>" in out


def test_user_text_containing_literal_CB_pattern_is_safe():
    # Text like "CB2" in user content must not be interpreted as a sentinel.
    # Even if the converter has 0 placeholders, "CB2" must come through intact.
    out = md_to_tg_html("see ticket CB2 and CB99")
    # CB tokens here are user input — must not be replaced; we just
    # need to ensure no PUA leaks (clean) and tokens survive.
    assert_clean(out)
    # The actual important assertion: tokens are preserved literally.
    assert "CB2" in out
    assert "CB99" in out


def test_html_escape_of_literals():
    out = md_to_tg_html("a < b & c > d")
    assert_clean(out)
    assert "&lt;" in out
    assert "&amp;" in out
    assert "&gt;" in out


def test_supported_html_passes_through():
    out = md_to_tg_html("<b>already bold</b>")
    assert_clean(out)
    assert out == "<b>already bold</b>"


if __name__ == "__main__":
    failed = 0
    passed = 0
    for name, fn in list(globals().items()):
        if name.startswith("test_") and callable(fn):
            try:
                fn()
            except AssertionError as e:
                failed += 1
                print(f"FAIL {name}: {e}")
            except Exception as e:
                failed += 1
                print(f"ERROR {name}: {type(e).__name__}: {e}")
            else:
                passed += 1
                print(f"ok   {name}")
    print(f"\n{passed} passed, {failed} failed")
    sys.exit(1 if failed else 0)
