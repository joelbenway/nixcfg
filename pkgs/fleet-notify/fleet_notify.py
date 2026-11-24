#!/usr/bin/env python3
# Copyright (c) Joel Benway
# SPDX-License-Identifier: MIT
"""Fleet notification publisher CLI backed by self-hosted ntfy."""

from __future__ import annotations

import argparse
import http.client
import json
import os
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path
from typing import Any

DEFAULT_CONFIG_PATH = "/etc/fleet-notify/config.json"

PRIORITY_MAP: dict[str, int] = {
    "1": 1,
    "min": 1,
    "2": 2,
    "low": 2,
    "3": 3,
    "default": 3,
    "normal": 3,
    "4": 4,
    "high": 4,
    "5": 5,
    "urgent": 5,
    "max": 5,
}


class ConfigError(Exception):
    """Raised when notification configuration or token input is invalid."""


class PublishError(Exception):
    """Raised when publishing a notification to ntfy fails."""


@dataclass(frozen=True)
class NotifyConfig:
    host: str
    urls: tuple[str, ...]
    default_topic: str
    desktop_topics: tuple[str, ...]
    publish_token_file: str | None
    subscribe_token_file: str | None


def _sanitize_error_text(text: str, token: str | None = None) -> str:
    clean = text
    if token:
        clean = clean.replace(token, "[redacted]")
    return clean


def parse_priority(raw: str | int) -> int:
    if isinstance(raw, bool):
        raise ConfigError("priority must be an integer 1..5 or named level")
    key = str(raw).strip().lower()
    if key not in PRIORITY_MAP:
        raise ConfigError(
            "invalid priority (expected 1..5 or min/low/default/high/urgent)"
        )
    return PRIORITY_MAP[key]


def load_config(path: Path) -> NotifyConfig:
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError) as exc:
        raise ConfigError(f"cannot read config file {path}: {exc}") from exc
    except json.JSONDecodeError as exc:
        raise ConfigError(f"invalid JSON in {path}: {exc}") from exc

    if not isinstance(raw, dict):
        raise ConfigError("config root must be a JSON object")

    raw_host = raw.get("host")
    host = (
        raw_host.strip()
        if isinstance(raw_host, str) and raw_host.strip()
        else socket.gethostname()
    )

    raw_urls = raw.get("urls")
    if not isinstance(raw_urls, list) or not raw_urls:
        raise ConfigError("config.urls must be a non-empty list of URLs")
    urls: list[str] = []
    for item in raw_urls:
        if not isinstance(item, str) or not item.strip():
            raise ConfigError("each entry in config.urls must be a non-empty string")
        urls.append(item.strip().rstrip("/"))

    default_topic = raw.get("defaultTopic", "fleet-alerts")
    if not isinstance(default_topic, str) or not default_topic.strip():
        raise ConfigError("config.defaultTopic must be a non-empty string")

    raw_desktop_topics = raw.get("desktopTopics", ["fleet-alerts", "fleet-updates"])
    if not isinstance(raw_desktop_topics, list) or not raw_desktop_topics:
        raise ConfigError("config.desktopTopics must be a non-empty list")
    desktop_topics: list[str] = []
    for t in raw_desktop_topics:
        if not isinstance(t, str) or not t.strip():
            raise ConfigError("each entry in config.desktopTopics must be a non-empty string")
        desktop_topics.append(t.strip())

    pub_file = raw.get("publishTokenFile")
    if pub_file is not None and not isinstance(pub_file, str):
        raise ConfigError("config.publishTokenFile must be a string or null")

    sub_file = raw.get("subscribeTokenFile")
    if sub_file is not None and not isinstance(sub_file, str):
        raise ConfigError("config.subscribeTokenFile must be a string or null")

    return NotifyConfig(
        host=host,
        urls=tuple(urls),
        default_topic=default_topic.strip(),
        desktop_topics=tuple(desktop_topics),
        publish_token_file=pub_file,
        subscribe_token_file=sub_file,
    )


def read_token(path: str | None) -> str:
    if not path:
        raise ConfigError("notification token file is not configured")
    try:
        token = Path(path).read_text(encoding="utf-8").strip()
    except (OSError, UnicodeDecodeError) as exc:
        raise ConfigError(f"cannot read notification token file: {exc}") from exc
    if not token:
        raise ConfigError("notification token file is empty")
    if "\n" in token or "\r" in token:
        raise ConfigError("notification token must be a single line")
    return token


def publish_message(
    cfg: NotifyConfig,
    token: str,
    *,
    topic: str,
    title: str,
    message: str,
    priority: int = 3,
    tags: list[str] | None = None,
    click: str | None = None,
    markdown: bool = False,
    timeout: float = 5.0,
    opener: Callable[..., Any] | None = None,
) -> None:
    if not topic.strip():
        raise ConfigError("topic must be non-empty")

    payload: dict[str, Any] = {
        "topic": topic.strip(),
        "title": title,
        "message": message,
        "priority": parse_priority(priority),
    }
    if tags:
        clean_tags = [t.strip() for t in tags if t.strip()]
        if clean_tags:
            payload["tags"] = clean_tags
    if click:
        payload["click"] = click
    if markdown:
        payload["markdown"] = True

    data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    open_fn = opener if opener is not None else urllib.request.urlopen

    last_error = "no ntfy URLs configured"
    for base_url in cfg.urls:
        for attempt in range(2):
            req = urllib.request.Request(
                base_url,
                data=data,
                method="POST",
                headers={
                    "Authorization": f"Bearer {token}",
                    "Content-Type": "application/json",
                },
            )
            try:
                with open_fn(req, timeout=timeout) as resp:
                    status = getattr(resp, "status", 200)
                    if 200 <= status < 300:
                        return
                    last_error = f"{base_url} returned HTTP {status}"
                    if 400 <= status < 500 and status != 429:
                        raise PublishError(
                            _sanitize_error_text(last_error, token)
                        )
            except urllib.error.HTTPError as exc:
                code = exc.code
                last_error = _sanitize_error_text(
                    f"{base_url} returned HTTP {code}: {exc.reason}", token
                )
                if 400 <= code < 500 and code != 429:
                    raise PublishError(last_error) from exc
            except (
                urllib.error.URLError,
                http.client.HTTPException,
                TimeoutError,
                OSError,
            ) as exc:
                last_error = _sanitize_error_text(
                    f"{base_url} request failed: {exc}", token
                )
            if attempt == 0:
                time.sleep(0.5)

    raise PublishError(_sanitize_error_text(last_error, token))


def collect_unit_failure(
    unit: str,
    host: str,
    runner: Callable[..., subprocess.CompletedProcess[str]] | None = None,
) -> tuple[str, str]:
    run_fn = runner if runner is not None else subprocess.run
    title = f"[{host}] Service failed: {unit}"

    status_lines: list[str] = []
    try:
        show = run_fn(
            [
                "systemctl",
                "show",
                unit,
                "-p",
                "Result",
                "-p",
                "ExecMainStatus",
                "-p",
                "ActiveState",
            ],
            capture_output=True,
            text=True,
            check=False,
            timeout=5,
        )
        if show.returncode == 0 and show.stdout.strip():
            status_lines.append(show.stdout.strip())
    except (subprocess.TimeoutExpired, OSError) as exc:
        status_lines.append(f"(systemctl show unavailable: {exc})")

    journal_text = ""
    try:
        journal = run_fn(
            [
                "journalctl",
                "-u",
                unit,
                "-n",
                "15",
                "--no-pager",
                "--output=short-iso",
            ],
            capture_output=True,
            text=True,
            check=False,
            timeout=5,
        )
        if journal.returncode == 0 and journal.stdout.strip():
            journal_text = journal.stdout.strip()
    except (subprocess.TimeoutExpired, OSError) as exc:
        journal_text = f"(journalctl unavailable: {exc})"

    parts: list[str] = []
    if status_lines:
        parts.append("\n".join(status_lines))
    if journal_text:
        parts.append(f"Recent logs:\n{journal_text}")
    body = "\n\n".join(parts) if parts else f"Systemd unit {unit} failed on {host}."
    # Keep payload comfortably below ntfy's 4096-byte inline message limit
    if len(body.encode("utf-8")) > 3500:
        body = body.encode("utf-8")[:3500].decode("utf-8", errors="ignore") + "\n...(truncated)"
    return title, body


def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="fleet-notify",
        description="Publish notifications to the fleet ntfy bus.",
    )
    parser.add_argument(
        "--config",
        default=os.environ.get("FLEET_NOTIFY_CONFIG") or DEFAULT_CONFIG_PATH,
        help="Path to non-secret fleet-notify JSON config",
    )
    parser.add_argument("--topic", default=None, help="Target ntfy topic")
    parser.add_argument(
        "--priority",
        default=None,
        help="Priority 1..5 or min|low|default|high|urgent",
    )
    parser.add_argument("--title", default=None, help="Notification title")
    parser.add_argument("--tags", default="", help="Comma-separated ntfy tags")
    parser.add_argument("--click", default=None, help="Optional click-through URL")
    parser.add_argument(
        "--markdown", action="store_true", help="Render message body as Markdown"
    )
    parser.add_argument(
        "--stdin", action="store_true", help="Read message body from stdin"
    )
    parser.add_argument(
        "--unit",
        default=None,
        help="Collect failure status and recent journal logs for a systemd unit",
    )
    parser.add_argument(
        "--best-effort",
        action="store_true",
        help="Log errors to stderr and exit 0 on failure",
    )
    parser.add_argument("message", nargs="?", default=None, help="Message body")
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_arg_parser()
    args = parser.parse_args(argv)
    token: str | None = None
    try:
        cfg = load_config(Path(args.config))
        token = read_token(cfg.publish_token_file)

        if args.unit:
            default_title, message = collect_unit_failure(args.unit, cfg.host)
            title = args.title or default_title
            topic = args.topic or "fleet-alerts"
            priority = parse_priority(args.priority if args.priority is not None else "high")
            tags = (
                [t.strip() for t in args.tags.split(",") if t.strip()]
                if args.tags
                else ["rotating_light", "gear"]
            )
        else:
            if args.stdin:
                message = sys.stdin.read().rstrip("\n")
            elif args.message is not None:
                message = args.message
            else:
                raise ConfigError("message argument, --stdin, or --unit is required")
            title = args.title or f"[{cfg.host}] Notification"
            topic = args.topic or cfg.default_topic
            priority = parse_priority(
                args.priority if args.priority is not None else "default"
            )
            tags = [t.strip() for t in args.tags.split(",") if t.strip()]

        publish_message(
            cfg,
            token,
            topic=topic,
            title=title,
            message=message,
            priority=priority,
            tags=tags,
            click=args.click,
            markdown=args.markdown,
        )
        return 0
    except (
        ConfigError,
        PublishError,
        http.client.HTTPException,
        ValueError,
        OSError,
    ) as exc:
        msg = _sanitize_error_text(str(exc), token)
        print(f"fleet-notify: {msg}", file=sys.stderr)
        return 0 if args.best_effort else 1


if __name__ == "__main__":
    sys.exit(main())
