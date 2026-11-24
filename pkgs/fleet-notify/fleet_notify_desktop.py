#!/usr/bin/env python3
# Copyright (c) Joel Benway
# SPDX-License-Identifier: MIT
"""Desktop notification subscriber streaming fleet ntfy topics to notify-send."""

from __future__ import annotations

import argparse
import json
import os
import signal
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from collections.abc import Callable, Iterable
from pathlib import Path
from typing import Any

from fleet_notify import (
    DEFAULT_CONFIG_PATH,
    ConfigError,
    _sanitize_error_text,
    load_config,
    read_token,
)

ERROR_TAGS = frozenset({"rotating_light", "warning", "x", "skull", "fire", "bangbang"})
REBOOT_TAGS = frozenset({"arrows_counterclockwise", "reboot", "recycle", "repeat"})
DISK_TAGS = frozenset({"cd", "floppy_disk", "minidisc", "dvd", "disk"})


def _default_cursor_path() -> Path:
    xdg = os.environ.get("XDG_STATE_HOME")
    base = Path(xdg) if xdg else Path.home() / ".local" / "state"
    return base / "fleet-notify" / "cursor.json"


def load_cursor(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        return data if isinstance(data, dict) else {}
    except (OSError, json.JSONDecodeError) as exc:
        print(
            f"fleet-notify-desktop: ignoring unreadable cursor {path}: {exc}",
            file=sys.stderr,
        )
        return {}


def save_cursor(path: Path, last_id: str, last_time: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = json.dumps({"last_id": last_id, "last_time": last_time}) + "\n"
    fd, tmp_name = tempfile.mkstemp(prefix=".cursor.", dir=str(path.parent))
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(payload)
        os.replace(tmp_name, path)
    except BaseException:
        try:
            os.unlink(tmp_name)
        except OSError:
            pass
        raise


def priority_to_urgency(priority: int) -> str:
    if priority >= 4:
        return "critical"
    if priority <= 2:
        return "low"
    return "normal"


def tags_to_icon(tags: list[str]) -> str:
    lowered = {t.strip().lower() for t in tags if isinstance(t, str)}
    if lowered & ERROR_TAGS:
        return "dialog-error"
    if lowered & REBOOT_TAGS:
        return "system-reboot"
    if lowered & DISK_TAGS:
        return "drive-harddisk"
    return "dialog-information"


def build_stream_url(base_url: str, topics: Iterable[str], since: str) -> str:
    topic_path = ",".join(urllib.parse.quote(t.strip(), safe="") for t in topics if t.strip())
    query = urllib.parse.urlencode({"since": since})
    return f"{base_url.rstrip('/')}/{topic_path}/json?{query}"


def dispatch_notification(
    event: dict[str, Any],
    runner: Callable[..., subprocess.CompletedProcess[str]] | None = None,
) -> bool:
    run_fn = runner if runner is not None else subprocess.run
    raw_priority = event.get("priority", 3)
    priority = raw_priority if isinstance(raw_priority, int) else 3
    urgency = priority_to_urgency(priority)

    raw_tags = event.get("tags", [])
    tags = [t for t in raw_tags if isinstance(t, str)] if isinstance(raw_tags, list) else []
    icon = tags_to_icon(tags)

    topic = str(event.get("topic") or "fleet")
    title = str(event.get("title") or f"[{topic}] Notification")
    message = str(event.get("message") or "")

    cmd = [
        "notify-send",
        "--app-name=NixOS Fleet",
        f"--urgency={urgency}",
        f"--icon={icon}",
        "--",
        title,
        message,
    ]
    try:
        res = run_fn(cmd, capture_output=True, text=True, check=False, timeout=10)
        if res.returncode != 0:
            print(
                f"fleet-notify-desktop: notify-send exited {res.returncode}: {res.stderr.strip()}",
                file=sys.stderr,
            )
            return False
        return True
    except (subprocess.TimeoutExpired, OSError) as exc:
        print(f"fleet-notify-desktop: notify-send failed: {exc}", file=sys.stderr)
        return False


def process_stream(
    lines: Iterable[bytes | str],
    cursor_path: Path,
    seen_id: str | None,
    dispatch_fn: Callable[[dict[str, Any]], bool] | None = None,
    on_activity: Callable[[], None] | None = None,
) -> str | None:
    dispatch = dispatch_fn if dispatch_fn is not None else dispatch_notification
    last_id = seen_id
    for raw_line in lines:
        text = (
            raw_line.decode("utf-8", errors="replace").strip()
            if isinstance(raw_line, (bytes, bytearray))
            else raw_line.strip()
        )
        if not text:
            continue
        try:
            event = json.loads(text)
        except json.JSONDecodeError:
            continue
        if not isinstance(event, dict):
            continue
        if on_activity is not None:
            on_activity()
        if event.get("event") != "message":
            continue
        msg_id = event.get("id")
        if not isinstance(msg_id, str) or not msg_id:
            continue
        if msg_id == last_id:
            continue
        dispatch(event)
        msg_time = event.get("time")
        ts = msg_time if isinstance(msg_time, int) else int(time.time())
        save_cursor(cursor_path, msg_id, ts)
        last_id = msg_id
    return last_id


def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="fleet-notify-desktop",
        description="Stream fleet ntfy alerts to freedesktop desktop notifications.",
    )
    parser.add_argument(
        "--config",
        default=os.environ.get("FLEET_NOTIFY_CONFIG", DEFAULT_CONFIG_PATH),
        help="Path to non-secret fleet-notify JSON config",
    )
    parser.add_argument(
        "--cursor",
        default=str(_default_cursor_path()),
        help="Path to persisted last-seen message cursor JSON",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_arg_parser()
    args = parser.parse_args(argv)
    config_path = Path(args.config)
    cursor_path = Path(args.cursor)

    stop_requested = False

    def _handle_signal(_signum: int, _frame: Any) -> None:
        nonlocal stop_requested
        stop_requested = True
        raise KeyboardInterrupt()

    prev_term = signal.getsignal(signal.SIGTERM)
    prev_int = signal.getsignal(signal.SIGINT)
    signal.signal(signal.SIGTERM, _handle_signal)
    signal.signal(signal.SIGINT, _handle_signal)

    backoff = 2.0
    url_index = 0
    try:
        while not stop_requested:
            token: str | None = None
            try:
                cfg = load_config(config_path)
                token = read_token(cfg.subscribe_token_file)
                cursor = load_cursor(cursor_path)
                raw_last_id = cursor.get("last_id")
                last_id = raw_last_id if isinstance(raw_last_id, str) and raw_last_id else None
                since = last_id if last_id is not None else "10m"

                base_url = cfg.urls[url_index % len(cfg.urls)]
                url_index += 1
                stream_url = build_stream_url(base_url, cfg.desktop_topics, since)
                req = urllib.request.Request(
                    stream_url,
                    method="GET",
                    headers={"Authorization": f"Bearer {token}"},
                )

                def _reset_backoff() -> None:
                    nonlocal backoff
                    backoff = 2.0

                with urllib.request.urlopen(req, timeout=70) as resp:
                    process_stream(
                        resp,
                        cursor_path,
                        seen_id=last_id,
                        on_activity=_reset_backoff,
                    )
            except KeyboardInterrupt:
                break
            except (ConfigError, urllib.error.URLError, TimeoutError, OSError) as exc:
                msg = _sanitize_error_text(str(exc), token)
                print(
                    f"fleet-notify-desktop: stream disconnected ({msg}); retrying in {backoff:.0f}s",
                    file=sys.stderr,
                )
            try:
                time.sleep(backoff)
            except KeyboardInterrupt:
                break
            backoff = min(backoff * 2.0, 60.0)
    finally:
        signal.signal(signal.SIGTERM, prev_term)
        signal.signal(signal.SIGINT, prev_int)

    return 0


if __name__ == "__main__":
    sys.exit(main())
