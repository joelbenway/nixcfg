# Copyright (c) Joel Benway
# SPDX-License-Identifier: MIT
import io
import json
import sys
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import parse_qs, urlparse

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent))
import beszel_query as bq  # noqa: E402


class FakeResponse:
    def __init__(self, payload: bytes, status: int = 200):
        self._payload = payload
        self.status = status

    def read(self) -> bytes:
        return self._payload

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, tb):
        return False


class FakeOpener:
    def __init__(self, handler):
        self.handler = handler
        self.requests = []

    def open(self, req, timeout=None):
        self.requests.append((req.get_method(), req.full_url, req.data, dict(req.header_items())))
        return self.handler(req)


def _json_resp(obj: dict) -> FakeResponse:
    return FakeResponse(json.dumps(obj).encode("utf-8"))


def _base_handler(extra=None):
    systems_payload = {
        "items": [
            {
                "id": "sys_zita",
                "name": "zita",
                "host": "127.0.0.1",
                "status": "up",
                "info": {
                    "cpu": 18.4,
                    "mp": 42.1,
                    "dp": 61.5,
                    "t": 52.0,
                    "g": 12.0,
                    "u": 86400,
                },
            },
            {
                "id": "sys_agnes",
                "name": "agnes",
                "host": "agnes.gentoo-humboldt.ts.net",
                "status": "down",
                "info": None,
            },
        ]
    }

    def handler(req):
        parsed = urlparse(req.full_url)
        if parsed.path == "/api/collections/users/auth-with-password":
            return _json_resp({"token": "tok_readonly_123"})
        if parsed.path == "/api/collections/systems/records":
            return _json_resp(systems_payload)
        if extra is not None:
            resp = extra(req, parsed)
            if resp is not None:
                return resp
        raise AssertionError(f"Unexpected request: {req.get_method()} {req.full_url}")

    return handler


def test_load_env_file_parses_quotes_and_comments(tmp_path, monkeypatch):
    monkeypatch.delenv("BESZEL_URL", raising=False)
    monkeypatch.delenv("BESZEL_API_EMAIL", raising=False)
    monkeypatch.delenv("BESZEL_API_PASSWORD", raising=False)
    monkeypatch.delenv("BESZEL_ENV_FILE", raising=False)

    env_file = tmp_path / "beszel-hermes.env"
    env_file.write_text(
        "# Comment line\n"
        "\n"
        'BESZEL_URL="http://127.0.0.1:8090"\n'
        "BESZEL_API_EMAIL='hermes@benway.me'\n"
        "BESZEL_API_PASSWORD=pw_from_file\n",
        encoding="utf-8",
    )

    url, email, password = bq.load_config(str(env_file))
    assert url == "http://127.0.0.1:8090"
    assert email == "hermes@benway.me"
    assert password == "pw_from_file"

    # Existing process env vars must take precedence over env file values
    monkeypatch.setenv("BESZEL_API_EMAIL", "override@benway.me")
    monkeypatch.setenv("BESZEL_ENV_FILE", str(env_file))
    url2, email2, password2 = bq.load_config(None)
    assert url2 == "http://127.0.0.1:8090"
    assert email2 == "override@benway.me"
    assert password2 == "pw_from_file"


def test_summary_renders_online_and_offline_laptops(monkeypatch, capsys):
    monkeypatch.setenv("BESZEL_URL", "http://127.0.0.1:8090")
    monkeypatch.setenv("BESZEL_API_EMAIL", "hermes@benway.me")
    monkeypatch.setenv("BESZEL_API_PASSWORD", "pw")

    opener = FakeOpener(_base_handler())
    rc_json = bq.main(["summary", "--json"], opener=opener)
    assert rc_json == 0
    out_json = json.loads(capsys.readouterr().out)
    names = {item["name"]: item for item in out_json["systems"]}
    assert names["zita"]["status"] == "up"
    assert names["zita"]["cpu_pct"] == 18.4
    assert names["agnes"]["status"] == "down"
    assert names["agnes"]["cpu_pct"] is None

    rc_text = bq.main(["summary"], opener=opener)
    assert rc_text == 0
    text = capsys.readouterr().out
    assert "zita" in text
    assert "agnes" in text
    assert "down" in text


def test_host_unknown_name_exits_nonzero_with_valid_hosts(monkeypatch, capsys):
    monkeypatch.setenv("BESZEL_URL", "http://127.0.0.1:8090")
    monkeypatch.setenv("BESZEL_API_EMAIL", "hermes@benway.me")
    monkeypatch.setenv("BESZEL_API_PASSWORD", "pw")

    opener = FakeOpener(_base_handler())
    rc = bq.main(["host", "nonexistent"], opener=opener)
    assert rc != 0
    captured = capsys.readouterr()
    assert "Traceback" not in captured.err
    assert "zita" in captured.err
    assert "agnes" in captured.err


def test_host_fetches_recent_stats_with_time_filter(monkeypatch, capsys):
    monkeypatch.setenv("BESZEL_URL", "http://127.0.0.1:8090")
    monkeypatch.setenv("BESZEL_API_EMAIL", "hermes@benway.me")
    monkeypatch.setenv("BESZEL_API_PASSWORD", "pw")

    def extra(req, parsed):
        if parsed.path == "/api/collections/system_stats/records":
            return _json_resp(
                {
                    "items": [
                        {
                            "created": "2026-11-20 12:00:00.000Z",
                            "stats": {"cpu": 21.0, "mp": 40.0, "dp": 60.0},
                        }
                    ]
                }
            )
        return None

    opener = FakeOpener(_base_handler(extra))
    rc = bq.main(["host", "zita", "--hours", "2", "--json"], opener=opener)
    assert rc == 0
    data = json.loads(capsys.readouterr().out)
    assert data["host"]["name"] == "zita"
    assert len(data["stats"]) == 1

    stats_reqs = [r for r in opener.requests if "/api/collections/system_stats/records" in r[1]]
    assert len(stats_reqs) == 1
    qs = parse_qs(urlparse(stats_reqs[0][1]).query)
    assert qs["sort"] == ["-created"]
    assert "system='sys_zita'" in qs["filter"][0]
    assert "created>=" in qs["filter"][0]


def test_systemd_failed_and_logs_escape_special_chars(monkeypatch, capsys):
    monkeypatch.setenv("BESZEL_URL", "http://127.0.0.1:8090")
    monkeypatch.setenv("BESZEL_API_EMAIL", "hermes@benway.me")
    monkeypatch.setenv("BESZEL_API_PASSWORD", "pw")

    assert bq.escape_pb_filter("a'b\\c") == "a\\'b\\\\c"

    def extra(req, parsed):
        if parsed.path == "/api/collections/systemd_services/records":
            return _json_resp(
                {
                    "page": 1,
                    "perPage": 500,
                    "totalPages": 1,
                    "totalItems": 1,
                    "items": [
                        {
                            "system": "sys_zita",
                            "name": "container@copyparty.service",
                            "state": bq.SERVICE_STATE_FAILED,
                            "sub": bq.SERVICE_SUBSTATE_FAILED,
                        }
                    ],
                }
            )
        if parsed.path == "/api/beszel/systemd/logs":
            return _json_resp({"logs": "Nov 20 copyparty crashed"})
        return None

    opener = FakeOpener(_base_handler(extra))
    rc1 = bq.main(["systemd", "--host", "zita", "--failed", "--json"], opener=opener)
    assert rc1 == 0
    svc_data = json.loads(capsys.readouterr().out)
    assert svc_data["services"][0]["name"] == "container@copyparty.service"
    assert svc_data["services"][0]["state"] == 2
    assert svc_data["services"][0]["sub"] == 3

    svc_reqs = [r for r in opener.requests if "/api/collections/systemd_services/records" in r[1]]
    assert len(svc_reqs) == 1
    svc_qs = parse_qs(urlparse(svc_reqs[0][1]).query)
    assert svc_qs["filter"] == ["system='sys_zita' && (state=2 || sub=3)"]

    rc_text = bq.main(["systemd", "--host", "zita", "--failed"], opener=opener)
    assert rc_text == 0
    svc_text = capsys.readouterr().out
    assert "container@copyparty.service" in svc_text
    assert "state=failed sub=failed" in svc_text

    rc2 = bq.main(
        ["systemd", "--host", "zita", "--logs", "container@copyparty.service", "--json"],
        opener=opener,
    )
    assert rc2 == 0
    log_data = json.loads(capsys.readouterr().out)
    assert "copyparty crashed" in log_data["logs"]

    log_reqs = [r for r in opener.requests if "/api/beszel/systemd/logs" in r[1]]
    assert len(log_reqs) == 1
    assert "container%40copyparty.service" in log_reqs[0][1]
    qs = parse_qs(urlparse(log_reqs[0][1]).query)
    assert qs["system"] == ["sys_zita"]
    assert qs["service"] == ["container@copyparty.service"]


def test_smart_is_strictly_readonly(monkeypatch, capsys):
    monkeypatch.setenv("BESZEL_URL", "http://127.0.0.1:8090")
    monkeypatch.setenv("BESZEL_API_EMAIL", "hermes@benway.me")
    monkeypatch.setenv("BESZEL_API_PASSWORD", "pw")

    def extra(req, parsed):
        if parsed.path == "/api/collections/smart_devices/records":
            return _json_resp(
                {
                    "items": [
                        {
                            "system": "sys_zita",
                            "name": "/dev/sda",
                            "model": "ST24000DM001",
                            "state": "PASSED",
                            "temp": 34,
                        }
                    ]
                }
            )
        return None

    opener = FakeOpener(_base_handler(extra))
    rc = bq.main(["smart", "--host", "zita", "--json"], opener=opener)
    assert rc == 0
    data = json.loads(capsys.readouterr().out)
    assert data["devices"][0]["model"] == "ST24000DM001"
    for method, url, _, _ in opener.requests:
        assert "/smart/refresh" not in url
        if "/api/collections/smart_devices/records" in url:
            assert method == "GET"


def test_alerts_and_history(monkeypatch, capsys):
    monkeypatch.setenv("BESZEL_URL", "http://127.0.0.1:8090")
    monkeypatch.setenv("BESZEL_API_EMAIL", "hermes@benway.me")
    monkeypatch.setenv("BESZEL_API_PASSWORD", "pw")

    def extra(req, parsed):
        if parsed.path == "/api/collections/alerts/records":
            return _json_resp(
                {"items": [{"system": "sys_zita", "name": "Disk", "value": 85, "triggered": True}]}
            )
        if parsed.path == "/api/collections/alerts_history/records":
            return _json_resp(
                {
                    "items": [
                        {
                            "system": "sys_zita",
                            "name": "Disk",
                            "value": 88,
                            "created": "2026-11-20 11:00:00Z",
                            "resolved": "",
                        },
                        {
                            "system": "sys_zita",
                            "name": "CPU",
                            "value": 92,
                            "created": "2026-11-20 10:00:00Z",
                            "resolved": "2026-11-20 10:15:00Z",
                        },
                    ]
                }
            )
        return None

    opener = FakeOpener(_base_handler(extra))
    rc1 = bq.main(["alerts", "--json"], opener=opener)
    assert rc1 == 0
    assert json.loads(capsys.readouterr().out)["alerts"][0]["name"] == "Disk"

    rc1_text = bq.main(["alerts"], opener=opener)
    assert rc1_text == 0
    alerts_text = capsys.readouterr().out
    assert "triggered=True" in alerts_text

    rc2 = bq.main(["alerts", "--history", "--json"], opener=opener)
    assert rc2 == 0
    assert json.loads(capsys.readouterr().out)["history"][0]["value"] == 88

    rc2_text = bq.main(["alerts", "--history"], opener=opener)
    assert rc2_text == 0
    history_text = capsys.readouterr().out
    assert "triggered=" not in history_text
    assert "resolved=active" in history_text
    assert "resolved=2026-11-20 10:15:00Z" in history_text


@pytest.mark.parametrize("mode", ["urlerror", "http401", "http500", "badjson"])
def test_http_errors_and_unreachable_never_leak_password(mode, monkeypatch, capsys):
    secret = "super-secret-password-999"
    monkeypatch.setenv("BESZEL_URL", "http://127.0.0.1:8090")
    monkeypatch.setenv("BESZEL_API_EMAIL", "hermes@benway.me")
    monkeypatch.setenv("BESZEL_API_PASSWORD", secret)

    def failing_handler(req):
        if mode == "urlerror":
            raise URLError(f"connection refused ({secret})")
        if mode == "http401":
            raise HTTPError(
                req.full_url,
                401,
                "Unauthorized",
                hdrs=None,
                fp=io.BytesIO(f'{{"message":"bad password {secret}"}}'.encode("utf-8")),
            )
        if mode == "http500":
            raise HTTPError(
                req.full_url,
                500,
                "Internal Server Error",
                hdrs=None,
                fp=io.BytesIO(b"server exploded"),
            )
        return FakeResponse(b"not-valid-json{{{")

    opener = FakeOpener(failing_handler)
    rc = bq.main(["summary"], opener=opener)
    assert rc != 0
    captured = capsys.readouterr()
    assert "Traceback" not in captured.err
    assert secret not in captured.out
    assert secret not in captured.err
    assert captured.err.strip().startswith("error:")


def test_http_exception_and_invalid_url_and_hours_never_traceback(monkeypatch, capsys):
    from http.client import RemoteDisconnected

    secret = "super-secret-password-999"
    monkeypatch.setenv("BESZEL_URL", "http://127.0.0.1:8090")
    monkeypatch.setenv("BESZEL_API_EMAIL", "hermes@benway.me")
    monkeypatch.setenv("BESZEL_API_PASSWORD", secret)

    # 1. http.client.RemoteDisconnected (inherits Exception, not OSError)
    def disconnect_handler(req):
        raise RemoteDisconnected(f"Remote end closed connection ({secret})")

    rc = bq.main(["summary"], opener=FakeOpener(disconnect_handler))
    assert rc != 0
    err = capsys.readouterr().err
    assert "Traceback" not in err
    assert secret not in err
    assert err.strip().startswith("error:")

    # 2. Invalid BESZEL_URL missing scheme
    monkeypatch.setenv("BESZEL_URL", "127.0.0.1:8090")
    rc_url = bq.main(["summary"], opener=FakeOpener(_base_handler()))
    assert rc_url != 0
    err_url = capsys.readouterr().err
    assert "Traceback" not in err_url
    assert err_url.strip().startswith("error:")

    # 3. Invalid --hours values (<= 0, nan, inf, overflow)
    monkeypatch.setenv("BESZEL_URL", "http://127.0.0.1:8090")
    for bad_hours in ["0", "-2", "nan", "inf", "1e9"]:
        rc_h = bq.main(["host", "zita", "--hours", bad_hours], opener=FakeOpener(_base_handler()))
        assert rc_h != 0, f"expected non-zero exit for --hours {bad_hours}"
        err_h = capsys.readouterr().err
        assert "Traceback" not in err_h
        assert err_h.strip().startswith("error:")


def test_null_fields_in_records_render_cleanly_without_typeerror(monkeypatch, capsys):
    monkeypatch.setenv("BESZEL_URL", "http://127.0.0.1:8090")
    monkeypatch.setenv("BESZEL_API_EMAIL", "hermes@benway.me")
    monkeypatch.setenv("BESZEL_API_PASSWORD", "pw")

    def null_handler(req):
        parsed = urlparse(req.full_url)
        if parsed.path == "/api/collections/users/auth-with-password":
            return _json_resp({"token": "tok"})
        if parsed.path == "/api/collections/systems/records":
            return _json_resp({"items": [{"id": "sys_1", "name": None, "status": None, "info": None}]})
        if parsed.path == "/api/collections/systemd_services/records":
            return _json_resp({"items": [{"system": "sys_1", "name": None, "state": None, "sub": None}]})
        if parsed.path == "/api/collections/smart_devices/records":
            return _json_resp({"items": [{"system": "sys_1", "name": None, "model": None, "state": None, "temp": None}]})
        if parsed.path == "/api/collections/alerts/records":
            return _json_resp({"items": [{"system": None, "name": None, "value": None, "triggered": None}]})
        raise AssertionError(f"Unexpected {parsed.path}")

    opener = FakeOpener(null_handler)
    for argv in [["summary"], ["systemd"], ["smart"], ["alerts"]]:
        rc = bq.main(argv, opener=opener)
        assert rc == 0, f"failed on {argv}"
        out = capsys.readouterr().out
        assert out.strip() != ""
        assert "None" not in out


def test_collection_pagination_fetches_all_pages_and_preserves_single_page(monkeypatch, capsys):
    monkeypatch.setenv("BESZEL_URL", "http://127.0.0.1:8090")
    monkeypatch.setenv("BESZEL_API_EMAIL", "hermes@benway.me")
    monkeypatch.setenv("BESZEL_API_PASSWORD", "pw")

    stats_pages = {
        "1": [{"id": "s1", "created": "2026-11-20 12:02:00Z"}, {"id": "s2", "created": "2026-11-20 12:01:00Z"}],
        "2": [{"id": "s3", "created": "2026-11-20 12:00:00Z"}],
        "3": [{"id": "s4", "created": "2026-11-20 11:59:00Z"}],
    }
    alert_pages = {
        "1": [{"id": "a1", "system": "sys_zita", "name": "Disk", "value": 88}],
        "2": [{"id": "a2", "system": "sys_zita", "name": "CPU", "value": 95}],
    }

    def extra(req, parsed):
        qs = parse_qs(parsed.query)
        page = qs.get("page", ["1"])[0]
        if parsed.path == "/api/collections/system_stats/records":
            return _json_resp(
                {
                    "page": int(page),
                    "perPage": 200,
                    "totalPages": 3,
                    "totalItems": 4,
                    "items": stats_pages[page],
                }
            )
        if parsed.path == "/api/collections/alerts_history/records":
            return _json_resp(
                {
                    "page": int(page),
                    "perPage": 200,
                    "totalPages": 2,
                    "totalItems": 2,
                    "items": alert_pages[page],
                }
            )
        return None

    opener = FakeOpener(_base_handler(extra))
    rc_host = bq.main(["host", "zita", "--hours", "24", "--json"], opener=opener)
    assert rc_host == 0
    host_data = json.loads(capsys.readouterr().out)
    assert [row["id"] for row in host_data["stats"]] == ["s1", "s2", "s3", "s4"]

    stats_reqs = [r for r in opener.requests if "/api/collections/system_stats/records" in r[1]]
    assert len(stats_reqs) == 3
    qs1 = parse_qs(urlparse(stats_reqs[0][1]).query)
    qs2 = parse_qs(urlparse(stats_reqs[1][1]).query)
    qs3 = parse_qs(urlparse(stats_reqs[2][1]).query)
    assert "page" not in qs1
    assert qs2["page"] == ["2"]
    assert qs3["page"] == ["3"]
    assert qs1["filter"] == qs2["filter"] == qs3["filter"]
    assert qs1["sort"] == qs2["sort"] == qs3["sort"] == ["-created"]

    # systems collection returned no totalPages -> exactly 1 request
    sys_reqs = [r for r in opener.requests if "/api/collections/systems/records" in r[1]]
    assert len(sys_reqs) == 1

    rc_alerts = bq.main(["alerts", "--history", "--json"], opener=opener)
    assert rc_alerts == 0
    alert_data = json.loads(capsys.readouterr().out)
    assert [row["id"] for row in alert_data["history"]] == ["a1", "a2"]


