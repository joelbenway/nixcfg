# Copyright (c) Joel Benway
# SPDX-License-Identifier: MIT
from __future__ import annotations

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
