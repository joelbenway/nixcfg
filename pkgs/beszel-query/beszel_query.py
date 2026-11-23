#!/usr/bin/env python3
# Copyright (c) Joel Benway
# SPDX-License-Identifier: MIT
"""Read-only CLI for querying Beszel Hub's PocketBase REST API."""

from __future__ import annotations

import argparse
from datetime import datetime, timedelta, timezone
from http.client import HTTPException
import json
import math
import os
from pathlib import Path
import sys
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode, urlparse
from urllib.request import Request, build_opener

DEFAULT_URL = "http://127.0.0.1:8090"
DEFAULT_ENV_FILE = "/run/agenix/beszel-hermes.env"

# Beszel v0.21.0 systemd_services numeric enum values
# (internal/entities/systemd/systemd.go & internal/site/src/lib/enums.ts)
SERVICE_STATE_FAILED = 2
SERVICE_SUBSTATE_FAILED = 3

SERVICE_STATE_LABELS: dict[int, str] = {
    0: "active",
    1: "inactive",
    2: "failed",
    3: "activating",
    4: "deactivating",
    5: "reloading",
}

SERVICE_SUBSTATE_LABELS: dict[int, str] = {
    0: "dead",
    1: "running",
    2: "exited",
    3: "failed",
    4: "unknown",
}


class BeszelError(Exception):
    """Sanitized, user-facing error from beszel-query."""


def _sanitize(text: str, secret: str | None) -> str:
    if secret:
        return text.replace(secret, "[REDACTED]")
    return text


def _parse_env_file(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    try:
        raw = path.read_text(encoding="utf-8")
    except OSError:
        return values

    for line in raw.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#") or "=" not in stripped:
            continue
        key, val = stripped.split("=", 1)
        key = key.strip()
        val = val.strip()
        if len(val) >= 2 and val[0] == val[-1] and val[0] in ("'", '"'):
            val = val[1:-1]
        if key:
            values[key] = val
    return values


def load_config(env_file: str | None = None) -> tuple[str, str, str]:
    """Load (url, email, password) from env with fallback to env_file."""
    resolved_env_file = env_file or os.environ.get("BESZEL_ENV_FILE") or DEFAULT_ENV_FILE
    file_vals = _parse_env_file(Path(resolved_env_file))

    url = (os.environ.get("BESZEL_URL") or file_vals.get("BESZEL_URL") or DEFAULT_URL).rstrip("/")
    parsed_url = urlparse(url)
    if parsed_url.scheme not in ("http", "https") or not parsed_url.netloc:
        raise BeszelError(f"invalid BESZEL_URL '{url}': must include http:// or https:// scheme and host")
    email = os.environ.get("BESZEL_API_EMAIL") or file_vals.get("BESZEL_API_EMAIL") or ""
    password = os.environ.get("BESZEL_API_PASSWORD") or file_vals.get("BESZEL_API_PASSWORD") or ""

    if not email or not password:
        raise BeszelError(
            f"missing BESZEL_API_EMAIL or BESZEL_API_PASSWORD (checked env and {resolved_env_file})"
        )
    return url, email, password


def escape_pb_filter(value: str) -> str:
    """Escape backslashes and single quotes for PocketBase filter literals."""
    return value.replace("\\", "\\\\").replace("'", "\\'")


class BeszelClient:
    """Strictly read-only PocketBase client for Beszel Hub."""

    def __init__(
        self,
        base_url: str,
        email: str,
        password: str,
        timeout: float = 10.0,
        opener: Any = None,
    ) -> None:
        self.base_url = base_url.rstrip("/")
        self.email = email
        self.password = password
        self.timeout = timeout
        self._opener = opener if opener is not None else build_opener()
        self._token: str | None = None

    def _open_json(self, req: Request) -> dict[str, Any]:
        try:
            with self._opener.open(req, timeout=self.timeout) as resp:
                raw = resp.read()
        except HTTPError as exc:
            detail = f"HTTP {exc.code}"
            try:
                body = exc.read().decode("utf-8", errors="replace").strip()
                if body:
                    detail = f"{detail}: {body[:200]}"
            except Exception:
                pass
            raise BeszelError(
                _sanitize(f"request failed ({detail}) for {req.full_url}", self.password)
            ) from None
        except URLError as exc:
            raise BeszelError(
                _sanitize(f"cannot reach Beszel Hub at {self.base_url}: {exc.reason}", self.password)
            ) from None
        except (OSError, HTTPException, ValueError) as exc:
            raise BeszelError(
                _sanitize(f"network error talking to {self.base_url}: {exc}", self.password)
            ) from None

        try:
            parsed = json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise BeszelError(
                _sanitize(f"invalid JSON from Beszel Hub ({exc})", self.password)
            ) from None
        if not isinstance(parsed, dict):
            raise BeszelError("unexpected non-object JSON response from Beszel Hub")
        return parsed

    def authenticate(self) -> str:
        if self._token:
            return self._token
        payload = json.dumps({"identity": self.email, "password": self.password}).encode("utf-8")
        req = Request(
            f"{self.base_url}/api/collections/users/auth-with-password",
            data=payload,
            headers={"Content-Type": "application/json", "Accept": "application/json"},
            method="POST",
        )
        data = self._open_json(req)
        token = data.get("token")
        if not isinstance(token, str) or not token:
            raise BeszelError("authentication succeeded but response did not include a token")
        self._token = token
        return token

    def get_json(self, path: str, params: dict[str, str] | None = None) -> dict[str, Any]:
        token = self.authenticate()
        url = f"{self.base_url}{path}"
        if params:
            url = f"{url}?{urlencode(params)}"
        req = Request(
            url,
            headers={"Authorization": token, "Accept": "application/json"},
            method="GET",
        )
        return self._open_json(req)

    def _items(self, data: dict[str, Any]) -> list[dict[str, Any]]:
        items = data.get("items")
        if items is None:
            return []
        if not isinstance(items, list):
            raise BeszelError("unexpected non-list 'items' field from Beszel Hub")
        return [item for item in items if isinstance(item, dict)]

    def _list_records(
        self, path: str, params: dict[str, str] | None = None
    ) -> list[dict[str, Any]]:
        base_params = dict(params) if params else {}
        data = self.get_json(path, base_params or None)
        records = self._items(data)

        total_pages = data.get("totalPages")
        if not isinstance(total_pages, int) or isinstance(total_pages, bool) or total_pages <= 1:
            return records

        for page in range(2, total_pages + 1):
            page_params = dict(base_params)
            page_params["page"] = str(page)
            next_data = self.get_json(path, page_params)
            page_items = self._items(next_data)
            if not page_items:
                break
            records.extend(page_items)
            next_total = next_data.get("totalPages")
            if isinstance(next_total, int) and not isinstance(next_total, bool) and page >= next_total:
                break
        return records

    def list_systems(self) -> list[dict[str, Any]]:
        return self._list_records("/api/collections/systems/records", {"perPage": "200", "sort": "name"})

    def resolve_system(self, name: str) -> dict[str, Any]:
        systems = self.list_systems()
        for item in systems:
            if item.get("name") == name or item.get("id") == name:
                if not item.get("id"):
                    raise BeszelError(f"matched host '{name}' has no record id")
                return item
        available = ", ".join(sorted(str(s.get("name", "")) for s in systems if s.get("name")))
        raise BeszelError(f"unknown host '{name}' (available: {available or 'none'})")

    def get_host_stats(self, system_id: str, hours: float) -> list[dict[str, Any]]:
        if not math.isfinite(hours) or hours <= 0 or hours > 87600:
            raise BeszelError(f"invalid --hours value '{hours}': must be a finite number between 0 and 87600")
        try:
            cutoff = (datetime.now(timezone.utc) - timedelta(hours=hours)).strftime("%Y-%m-%d %H:%M:%S")
        except (ValueError, OverflowError) as exc:
            raise BeszelError(f"invalid --hours value '{hours}': {exc}") from None
        flt = f"system='{escape_pb_filter(system_id)}' && created>='{cutoff}'"
        return self._list_records(
            "/api/collections/system_stats/records",
            {"filter": flt, "sort": "-created", "perPage": "200"},
        )

    def list_systemd(
        self, system_id: str | None = None, failed_only: bool = False
    ) -> list[dict[str, Any]]:
        filters: list[str] = []
        if system_id:
            filters.append(f"system='{escape_pb_filter(system_id)}'")
        if failed_only:
            filters.append(f"(state={SERVICE_STATE_FAILED} || sub={SERVICE_SUBSTATE_FAILED})")
        params: dict[str, str] = {"perPage": "500", "sort": "name"}
        if filters:
            params["filter"] = " && ".join(filters)
        return self._list_records("/api/collections/systemd_services/records", params)

    def get_systemd_logs(self, system_id: str, service: str) -> str:
        data = self.get_json(
            "/api/beszel/systemd/logs",
            {"system": system_id, "service": service},
        )
        logs = data.get("logs")
        return logs if isinstance(logs, str) else json.dumps(data)

    def list_smart(self, system_id: str | None = None) -> list[dict[str, Any]]:
        params: dict[str, str] = {"perPage": "200", "sort": "name"}
        if system_id:
            params["filter"] = f"system='{escape_pb_filter(system_id)}'"
        return self._list_records("/api/collections/smart_devices/records", params)

    def list_alerts(
        self, system_id: str | None = None, history: bool = False
    ) -> list[dict[str, Any]]:
        collection = "alerts_history" if history else "alerts"
        params: dict[str, str] = {"perPage": "200", "sort": "-created"}
        if system_id:
            params["filter"] = f"system='{escape_pb_filter(system_id)}'"
        return self._list_records(f"/api/collections/{collection}/records", params)


def _format_system_row(item: dict[str, Any]) -> dict[str, Any]:
    info = item.get("info") if isinstance(item.get("info"), dict) else {}
    return {
        "id": item.get("id"),
        "name": item.get("name") or "?",
        "host": item.get("host"),
        "status": item.get("status") or "unknown",
        "uptime_sec": info.get("u"),
        "cpu_pct": info.get("cpu"),
        "mem_pct": info.get("mp"),
        "disk_pct": info.get("dp"),
        "temp_c": info.get("t"),
        "gpu_pct": info.get("g"),
    }


def _fmt_text(val: Any, default: str = "?") -> str:
    return default if val is None else str(val)


def _fmt_enum(val: Any, labels: dict[int, str], default: str = "?") -> str:
    if isinstance(val, int) and not isinstance(val, bool) and val in labels:
        return labels[val]
    return _fmt_text(val, default)


def _fmt_opt(val: Any, suffix: str = "") -> str:
    if val is None:
        return "-"
    if isinstance(val, float):
        return f"{val:.1f}{suffix}"
    return f"{val}{suffix}"


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="beszel-query",
        description="Read-only CLI for querying Beszel Hub metrics, SMART, systemd, and alerts.",
    )
    parser.add_argument(
        "--env-file",
        default=None,
        help=f"Path to env file with Beszel credentials (default: $BESZEL_ENV_FILE or {DEFAULT_ENV_FILE})",
    )
    sub = parser.add_subparsers(dest="command", required=True)

    p_summary = sub.add_parser("summary", help="Show fleet overview across all systems")
    p_summary.add_argument("--json", action="store_true", dest="as_json")

    p_host = sub.add_parser("host", help="Show host detail and recent stats")
    p_host.add_argument("name", help="System name (e.g. zita, michael, francis, agnes, jerome)")
    p_host.add_argument("--hours", type=float, default=1.0, help="Hours of stats history (default: 1)")
    p_host.add_argument("--json", action="store_true", dest="as_json")

    p_systemd = sub.add_parser("systemd", help="List systemd services or fetch unit logs")
    p_systemd.add_argument("--host", default=None, help="Filter by host name")
    p_systemd.add_argument("--failed", action="store_true", help="Only show failed services")
    p_systemd.add_argument("--logs", default=None, metavar="UNIT", help="Fetch recent logs for UNIT (requires --host)")
    p_systemd.add_argument("--json", action="store_true", dest="as_json")

    p_smart = sub.add_parser("smart", help="List cached SMART drive status (read-only)")
    p_smart.add_argument("--host", default=None, help="Filter by host name")
    p_smart.add_argument("--json", action="store_true", dest="as_json")

    p_alerts = sub.add_parser("alerts", help="List configured alerts or alert history")
    p_alerts.add_argument("--host", default=None, help="Filter by host name")
    p_alerts.add_argument("--history", action="store_true", help="Show alert history instead of rules")
    p_alerts.add_argument("--json", action="store_true", dest="as_json")

    return parser


def _run(args: argparse.Namespace, client: BeszelClient) -> None:
    if args.command == "summary":
        rows = [_format_system_row(s) for s in client.list_systems()]
        if args.as_json:
            print(json.dumps({"systems": rows}, indent=2))
            return
        print(f"{'HOST':<12} {'STATUS':<8} {'CPU':>7} {'MEM':>7} {'DISK':>7} {'TEMP':>7} {'GPU':>7}")
        for r in rows:
            print(
                f"{str(r['name']):<12} {str(r['status']):<8} "
                f"{_fmt_opt(r['cpu_pct'], '%'):>7} {_fmt_opt(r['mem_pct'], '%'):>7} "
                f"{_fmt_opt(r['disk_pct'], '%'):>7} {_fmt_opt(r['temp_c'], 'C'):>7} "
                f"{_fmt_opt(r['gpu_pct'], '%'):>7}"
            )
        return

    if args.command == "host":
        sys_rec = client.resolve_system(args.name)
        stats = client.get_host_stats(str(sys_rec["id"]), args.hours)
        row = _format_system_row(sys_rec)
        if args.as_json:
            print(json.dumps({"host": row, "hours": args.hours, "stats": stats}, indent=2))
            return
        print(
            f"{row['name']} ({row['status']}) cpu={_fmt_opt(row['cpu_pct'], '%')} "
            f"mem={_fmt_opt(row['mem_pct'], '%')} disk={_fmt_opt(row['disk_pct'], '%')} "
            f"temp={_fmt_opt(row['temp_c'], 'C')} samples={len(stats)} (last {args.hours:g}h)"
        )
        return

    if args.command == "systemd":
        sys_id = str(client.resolve_system(args.host)["id"]) if args.host else None
        if args.logs:
            if not sys_id:
                raise BeszelError("--logs requires --host <name>")
            logs = client.get_systemd_logs(sys_id, args.logs)
            if args.as_json:
                print(json.dumps({"host": args.host, "service": args.logs, "logs": logs}, indent=2))
            else:
                print(logs)
            return
        services = client.list_systemd(system_id=sys_id, failed_only=args.failed)
        if args.as_json:
            print(json.dumps({"services": services}, indent=2))
            return
        for svc in services:
            print(
                f"{_fmt_text(svc.get('name')):<40} "
                f"state={_fmt_enum(svc.get('state'), SERVICE_STATE_LABELS)} "
                f"sub={_fmt_enum(svc.get('sub'), SERVICE_SUBSTATE_LABELS)}"
            )
        return

    if args.command == "smart":
        sys_id = str(client.resolve_system(args.host)["id"]) if args.host else None
        devices = client.list_smart(system_id=sys_id)
        if args.as_json:
            print(json.dumps({"devices": devices}, indent=2))
            return
        for dev in devices:
            print(
                f"{_fmt_text(dev.get('name')):<16} model={_fmt_text(dev.get('model'))} "
                f"state={_fmt_text(dev.get('state'))} temp={_fmt_opt(dev.get('temp'), 'C')}"
            )
        return

    if args.command == "alerts":
        sys_id = str(client.resolve_system(args.host)["id"]) if args.host else None
        items = client.list_alerts(system_id=sys_id, history=args.history)
        key = "history" if args.history else "alerts"
        if args.as_json:
            print(json.dumps({key: items}, indent=2))
            return
        for item in items:
            print(
                f"{_fmt_text(item.get('name')):<16} system={_fmt_text(item.get('system'))} "
                f"value={_fmt_text(item.get('value'))} triggered={_fmt_text(item.get('triggered'), '-')}"
            )


def main(argv: list[str] | None = None, opener: Any = None) -> int:
    parser = _build_parser()
    args = parser.parse_args(argv)
    secret: str | None = None
    try:
        url, email, password = load_config(args.env_file)
        secret = password
        client = BeszelClient(url, email, password, opener=opener)
        _run(args, client)
        return 0
    except BeszelError as exc:
        print(f"error: {_sanitize(str(exc), secret)}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
