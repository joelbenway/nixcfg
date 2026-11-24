# Copyright (c) Joel Benway
# SPDX-License-Identifier: MIT
from __future__ import annotations

import http.client
import io
import json
import os
import subprocess
import sys
import urllib.error
from pathlib import Path
from typing import Any

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent))
import fleet_notify as fn


def _write_cfg(
    tmp_path: Path,
    *,
    urls: list[str] | None = None,
    pub_token: str | None = "tk_pub_secret_12345",
    sub_token: str | None = "tk_sub_secret_67890",
    host: str = "zita",
) -> Path:
    pub_path: str | None = None
    if pub_token is not None:
        p = tmp_path / "pub.token"
        p.write_text(f"{pub_token}\n", encoding="utf-8")
        pub_path = str(p)
    sub_path: str | None = None
    if sub_token is not None:
        s = tmp_path / "sub.token"
        s.write_text(f"{sub_token}\n", encoding="utf-8")
        sub_path = str(s)
    cfg_path = tmp_path / "config.json"
    cfg_path.write_text(
        json.dumps(
            {
                "host": host,
                "urls": urls if urls is not None else ["https://notify.example", "https://backup.example:2587"],
                "defaultTopic": "fleet-alerts",
                "desktopTopics": ["fleet-alerts", "fleet-updates"],
                "publishTokenFile": pub_path,
                "subscribeTokenFile": sub_path,
            }
        ),
        encoding="utf-8",
    )
    return cfg_path


class _FakeResponse:
    def __init__(self, status: int = 200, body: bytes = b"{}") -> None:
        self.status = status
        self._body = body

    def read(self) -> bytes:
        return self._body

    def __enter__(self) -> _FakeResponse:
        return self

    def __exit__(self, *_args: object) -> None:
        return None


def test_publish_json_payload_and_bearer_header(tmp_path: Path) -> None:
    cfg_path = _write_cfg(tmp_path)
    cfg = fn.load_config(cfg_path)
    token = fn.read_token(cfg.publish_token_file)

    captured: list[tuple[str, dict[str, str], dict[str, Any]]] = []

    def fake_opener(req: Any, timeout: float = 5.0) -> _FakeResponse:
        headers = {k.lower(): v for k, v in req.header_items()}
        body = json.loads(req.data.decode("utf-8"))
        captured.append((req.full_url, headers, body))
        return _FakeResponse(200)

    fn.publish_message(
        cfg,
        token,
        topic="fleet-alerts",
        title="[zita] Backup ⚠️",
        message="Disk space low",
        priority=fn.parse_priority("high"),
        tags=["warning", "cd"],
        click="https://metrics.benway.me",
        markdown=True,
        opener=fake_opener,
    )

    assert len(captured) == 1
    url, headers, body = captured[0]
    assert url == "https://notify.example"
    assert headers["authorization"] == "Bearer tk_pub_secret_12345"
    assert headers["content-type"] == "application/json"
    assert body == {
        "topic": "fleet-alerts",
        "title": "[zita] Backup ⚠️",
        "message": "Disk space low",
        "priority": 4,
        "tags": ["warning", "cd"],
        "click": "https://metrics.benway.me",
        "markdown": True,
    }


def test_publish_retries_transient_5xx_and_falls_back_to_second_url(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    cfg_path = _write_cfg(tmp_path)
    cfg = fn.load_config(cfg_path)
    token = fn.read_token(cfg.publish_token_file)
    monkeypatch.setattr(fn.time, "sleep", lambda _s: None)

    calls: list[str] = []

    def fake_opener(req: Any, timeout: float = 5.0) -> _FakeResponse:
        calls.append(req.full_url)
        if req.full_url == "https://notify.example":
            raise urllib.error.HTTPError(
                req.full_url, 503, "Service Unavailable", hdrs=None, fp=io.BytesIO(b"busy")
            )
        return _FakeResponse(200)

    fn.publish_message(
        cfg,
        token,
        topic="fleet-alerts",
        title="[zita] Test",
        message="Fallback check",
        opener=fake_opener,
    )
    # 1 initial + 1 retry on URL 1, then success on URL 2
    assert calls == [
        "https://notify.example",
        "https://notify.example",
        "https://backup.example:2587",
    ]


def test_publish_fails_fast_on_401_and_never_echoes_token(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    secret_tok = "tk_supersecret_never_log_me"
    cfg_path = _write_cfg(tmp_path, pub_token=secret_tok)
    monkeypatch.setattr(fn.time, "sleep", lambda _s: None)

    calls: list[str] = []

    def fake_opener(req: Any, timeout: float = 5.0) -> _FakeResponse:
        calls.append(req.full_url)
        raise urllib.error.HTTPError(
            req.full_url,
            401,
            "Unauthorized",
            hdrs=None,
            fp=io.BytesIO(f"invalid bearer {secret_tok}".encode("utf-8")),
        )

    monkeypatch.setattr(fn.urllib.request, "urlopen", fake_opener)
    rc = fn.main(["--config", str(cfg_path), "hello"])
    err = capsys.readouterr().err
    assert rc == 1
    assert calls == ["https://notify.example"]
    assert secret_tok not in err


def test_missing_token_file_best_effort_vs_strict(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    cfg_path = _write_cfg(tmp_path, pub_token=None)
    # Point publishTokenFile to a non-existent path
    raw = json.loads(cfg_path.read_text(encoding="utf-8"))
    raw["publishTokenFile"] = str(tmp_path / "does-not-exist.token")
    cfg_path.write_text(json.dumps(raw), encoding="utf-8")

    rc_best = fn.main(["--config", str(cfg_path), "--best-effort", "hello"])
    err_best = capsys.readouterr().err
    assert rc_best == 0
    assert "token" in err_best.lower()

    rc_strict = fn.main(["--config", str(cfg_path), "hello"])
    assert rc_strict == 1


def test_unit_failure_mode_collects_systemctl_and_journal_tail(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    cfg_path = _write_cfg(tmp_path, host="zita")
    sent: list[dict[str, Any]] = []

    def fake_run(args: list[str], **_kwargs: object) -> subprocess.CompletedProcess[str]:
        if args[0] == "systemctl":
            return subprocess.CompletedProcess(
                args, 0, stdout="Result=exit-code\nExecMainStatus=2\nActiveState=failed\n", stderr=""
            )
        if args[0] == "journalctl":
            return subprocess.CompletedProcess(
                args, 0, stdout="2026-11-24T10:00:00Z zita caddy[123]: bind failed\n", stderr=""
            )
        raise AssertionError(f"unexpected command: {args}")

    def fake_opener(req: Any, timeout: float = 5.0) -> _FakeResponse:
        sent.append(json.loads(req.data.decode("utf-8")))
        return _FakeResponse(200)

    monkeypatch.setattr(fn.subprocess, "run", fake_run)
    monkeypatch.setattr(fn.urllib.request, "urlopen", fake_opener)

    rc = fn.main(["--config", str(cfg_path), "--unit", "caddy.service"])
    assert rc == 0
    assert len(sent) == 1
    assert sent[0]["topic"] == "fleet-alerts"
    assert sent[0]["priority"] == 4
    assert sent[0]["tags"] == ["rotating_light", "gear"]
    assert sent[0]["title"] == "[zita] Service failed: caddy.service"
    assert "Result=exit-code" in sent[0]["message"]
    assert "bind failed" in sent[0]["message"]


def test_stdin_message_and_priority_aliases(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    assert fn.parse_priority("min") == 1
    assert fn.parse_priority("low") == 2
    assert fn.parse_priority("default") == 3
    assert fn.parse_priority("high") == 4
    assert fn.parse_priority("urgent") == 5
    assert fn.parse_priority("max") == 5
    assert fn.parse_priority(4) == 4
    with pytest.raises(fn.ConfigError):
        fn.parse_priority("extreme")

    cfg_path = _write_cfg(tmp_path, host="francis")
    sent: list[dict[str, Any]] = []
    monkeypatch.setattr(fn.sys, "stdin", io.StringIO("body from stdin\nline 2\n"))
    monkeypatch.setattr(
        fn.urllib.request,
        "urlopen",
        lambda req, timeout=5.0: (sent.append(json.loads(req.data.decode("utf-8"))) or _FakeResponse(200)),
    )

    rc = fn.main(["--config", str(cfg_path), "--priority", "urgent", "--stdin"])
    assert rc == 0
    assert sent[0]["priority"] == 5
    assert sent[0]["message"] == "body from stdin\nline 2"
    assert sent[0]["title"] == "[francis] Notification"


def test_stream_ignores_non_message_events_dedups_and_persists_0600_cursor(
    tmp_path: Path,
) -> None:
    import fleet_notify_desktop as fnd

    cursor_path = tmp_path / "state" / "cursor.json"
    dispatched: list[dict[str, Any]] = []
    lines = [
        json.dumps({"id": "o1", "time": 100, "event": "open", "topic": "fleet-alerts"}).encode(),
        json.dumps({"id": "k1", "time": 101, "event": "keepalive", "topic": "fleet-alerts"}).encode(),
        json.dumps(
            {
                "id": "m1",
                "time": 102,
                "event": "message",
                "topic": "fleet-alerts",
                "title": "[zita] Alert 1",
                "message": "First",
                "priority": 5,
                "tags": ["rotating_light"],
            }
        ).encode(),
        json.dumps(
            {
                "id": "m1",
                "time": 102,
                "event": "message",
                "topic": "fleet-alerts",
                "title": "[zita] Alert 1",
                "message": "First duplicate",
                "priority": 5,
            }
        ).encode(),
        json.dumps(
            {
                "id": "m2",
                "time": 105,
                "event": "message",
                "topic": "fleet-updates",
                "title": "[francis] Reboot",
                "message": "Kernel updated",
                "priority": 3,
                "tags": ["arrows_counterclockwise"],
            }
        ).encode(),
        json.dumps({"id": "p1", "time": 106, "event": "poll_request", "topic": "fleet-alerts"}).encode(),
    ]

    last_id = fnd.process_stream(
        lines,
        cursor_path,
        seen_id=None,
        dispatch_fn=lambda ev: (dispatched.append(ev) or True),
    )

    assert last_id == "m2"
    assert [d["id"] for d in dispatched] == ["m1", "m2"]
    assert cursor_path.exists()
    assert (cursor_path.stat().st_mode & 0o777) == 0o600
    saved = json.loads(cursor_path.read_text(encoding="utf-8"))
    assert saved["last_id"] == "m2"
    assert saved["last_time"] == 105


def test_corrupt_cursor_file_falls_back_to_10m_since(tmp_path: Path) -> None:
    import fleet_notify_desktop as fnd

    cursor_path = tmp_path / "cursor.json"
    cursor_path.write_text("{corrupt json", encoding="utf-8")
    assert fnd.load_cursor(cursor_path) == {}
    url = fnd.build_stream_url(
        "https://notify.example",
        ["fleet-alerts", "fleet-updates"],
        since=fnd.load_cursor(cursor_path).get("last_id") or "10m",
    )
    assert url == "https://notify.example/fleet-alerts,fleet-updates/json?since=10m"


def test_priority_urgency_and_tag_icon_mapping() -> None:
    import fleet_notify_desktop as fnd

    assert fnd.priority_to_urgency(5) == "critical"
    assert fnd.priority_to_urgency(4) == "critical"
    assert fnd.priority_to_urgency(3) == "normal"
    assert fnd.priority_to_urgency(2) == "low"
    assert fnd.priority_to_urgency(1) == "low"

    assert fnd.tags_to_icon(["rotating_light", "nix"]) == "dialog-error"
    assert fnd.tags_to_icon(["warning"]) == "dialog-error"
    assert fnd.tags_to_icon(["arrows_counterclockwise"]) == "system-reboot"
    assert fnd.tags_to_icon(["cd"]) == "drive-harddisk"
    assert fnd.tags_to_icon([]) == "dialog-information"


def test_dispatch_notification_passes_double_dash_and_handles_timeout() -> None:
    import fleet_notify_desktop as fnd

    recorded: list[list[str]] = []

    def fake_run(args: list[str], **_kwargs: object) -> subprocess.CompletedProcess[str]:
        recorded.append(args)
        return subprocess.CompletedProcess(args, 0, "", "")

    ok = fnd.dispatch_notification(
        {
            "id": "m9",
            "topic": "fleet-alerts",
            "title": "--leading-hyphen-title",
            "message": "--leading-hyphen-body",
            "priority": 4,
            "tags": ["warning"],
        },
        runner=fake_run,
    )
    assert ok is True
    assert recorded[0][:4] == [
        "notify-send",
        "--app-name=NixOS Fleet",
        "--urgency=critical",
        "--icon=dialog-error",
    ]
    assert recorded[0][4:] == ["--", "--leading-hyphen-title", "--leading-hyphen-body"]

    def timeout_run(args: list[str], **_kwargs: object) -> subprocess.CompletedProcess[str]:
        raise subprocess.TimeoutExpired(cmd=args, timeout=10)

    assert (
        fnd.dispatch_notification(
            {"id": "m10", "title": "T", "message": "M", "priority": 3},
            runner=timeout_run,
        )
        is False
    )


def test_missing_subscribe_token_sleeps_with_backoff_without_crashing(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    import fleet_notify_desktop as fnd

    cfg_path = _write_cfg(tmp_path, sub_token=None)
    raw = json.loads(cfg_path.read_text(encoding="utf-8"))
    raw["subscribeTokenFile"] = str(tmp_path / "missing-sub.token")
    cfg_path.write_text(json.dumps(raw), encoding="utf-8")

    slept: list[float] = []
    stop_after = [2]

    def fake_sleep(sec: float) -> None:
        slept.append(sec)
        stop_after[0] -= 1
        if stop_after[0] <= 0:
            raise KeyboardInterrupt()

    monkeypatch.setattr(fnd.time, "sleep", fake_sleep)
    rc = fnd.main(["--config", str(cfg_path), "--cursor", str(tmp_path / "cursor.json")])
    assert rc == 0
    assert len(slept) == 2
    assert slept[1] > slept[0]


def test_publish_retries_incomplete_read_and_429_and_handles_corrupt_token(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    cfg_path = _write_cfg(tmp_path)
    cfg = fn.load_config(cfg_path)
    token = fn.read_token(cfg.publish_token_file)
    monkeypatch.setattr(fn.time, "sleep", lambda _s: None)

    calls: list[str] = []

    def fake_opener(req: Any, timeout: float = 5.0) -> _FakeResponse:
        calls.append(req.full_url)
        if len(calls) == 1:
            raise http.client.IncompleteRead(b"partial")
        if len(calls) == 2:
            raise urllib.error.HTTPError(
                req.full_url, 429, "Too Many Requests", hdrs=None, fp=io.BytesIO(b"slow down")
            )
        return _FakeResponse(200)

    fn.publish_message(
        cfg,
        token,
        topic="fleet-alerts",
        title="[zita] Test",
        message="Retry check",
        opener=fake_opener,
    )
    assert calls == [
        "https://notify.example",
        "https://notify.example",
        "https://backup.example:2587",
    ]

    # Corrupt non-UTF-8 token file under --best-effort exits 0 cleanly
    assert cfg.publish_token_file is not None
    Path(cfg.publish_token_file).write_bytes(b"\xff\xfe\xfd")
    rc = fn.main(["--config", str(cfg_path), "--best-effort", "--", "-leading-dash-body"])
    err = capsys.readouterr().err
    assert rc == 0
    assert "token" in err.lower()


def test_desktop_recovers_from_incomplete_read_and_failed_dispatch_preserves_cursor(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    import fleet_notify_desktop as fnd

    # 1. Failed dispatch must not advance persisted cursor
    cursor_path = tmp_path / "cursor.json"
    msg_line = json.dumps(
        {
            "id": "m99",
            "time": 200,
            "event": "message",
            "topic": "fleet-alerts",
            "title": "Test\x00Title",
            "message": "Body\x00Here",
            "priority": 4,
        }
    ).encode()
    last_id = fnd.process_stream(
        [msg_line],
        cursor_path,
        seen_id=None,
        dispatch_fn=lambda _ev: False,
    )
    assert last_id is None
    assert not cursor_path.exists()

    # 2. dispatch_notification strips NUL bytes cleanly
    recorded: list[list[str]] = []

    def fake_run(args: list[str], **_kwargs: object) -> subprocess.CompletedProcess[str]:
        recorded.append(args)
        return subprocess.CompletedProcess(args, 0, "", "")

    assert (
        fnd.dispatch_notification(
            {"id": "m99", "title": "Bad\x00Title", "message": "Bad\x00Body", "priority": 3},
            runner=fake_run,
        )
        is True
    )
    assert recorded[0][-2:] == ["BadTitle", "BadBody"]

    # 3. IncompleteRead mid-stream triggers backoff reconnect rather than unhandled crash
    cfg_path = _write_cfg(tmp_path)
    slept: list[float] = []

    def fake_urlopen(_req: Any, timeout: float = 70) -> Any:
        raise http.client.IncompleteRead(b"truncated chunk")

    def fake_sleep(sec: float) -> None:
        slept.append(sec)
        raise KeyboardInterrupt()

    monkeypatch.setattr(fnd.urllib.request, "urlopen", fake_urlopen)
    monkeypatch.setattr(fnd.time, "sleep", fake_sleep)
    rc = fnd.main(["--config", str(cfg_path), "--cursor", str(cursor_path)])
    assert rc == 0
    assert slept == [2.0]
