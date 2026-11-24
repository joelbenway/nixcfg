#!/usr/bin/env python3
# Copyright (c) Joel Benway
# SPDX-License-Identifier: MIT
"""Idempotent declarative KMail provisioner for KDE Plasma 6 / Akonadi / QtKeychain."""

from __future__ import annotations

import argparse
import contextlib
import fcntl
import hashlib
import json
import logging
import os
import re
import subprocess
import sys
import tempfile
import time
from collections.abc import Callable, Iterator
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Protocol

LOG = logging.getLogger("kmail-provision")

EXIT_OK = 0
EXIT_CONFIG_ERROR = 1
EXIT_SESSION_NOT_READY = 2
EXIT_PROVISION_ERROR = 3


class ConfigError(Exception):
    """Raised when the JSON account specification is invalid."""


class SessionNotReadyError(Exception):
    """Raised when Akonadi or QtKeychain/KWallet is unavailable or locked."""


class ProvisionError(Exception):
    """Raised when a provisioning step fails."""


class GpgLookupError(Exception):
    """Raised when gpg --list-secret-keys fails transiently."""


# Exact MailTransport::TransportBase::EnumAuthenticationType values
# verified from mailtransport.kcfg and akonadi_imap_resource (KDE PIM 26.08.2).
IMAP_AUTH_ENUM: dict[str, int] = {
    "LOGIN": 0,
    "PLAIN": 1,
    "CRAM_MD5": 2,
    "DIGEST_MD5": 3,
    "GSSAPI": 4,
    "NTLM": 5,
    "APOP": 6,
    "CLEAR": 7,
    "ANONYMOUS": 8,
    "XOAUTH2": 9,
}

# APOP is POP3-only; KDE PIM 26.08.2 IMAP has no mapping for it.
VALID_IMAP_AUTH = frozenset(IMAP_AUTH_ENUM.keys()) - {"APOP"}
VALID_IMAP_SAFETY = frozenset({"SSL", "STARTTLS", "None"})
VALID_SMTP_ENCRYPTION = frozenset({"SSL", "TLS", "None"})
VALID_SMTP_AUTH = frozenset(IMAP_AUTH_ENUM.keys())
VALID_PROVIDERS = frozenset({"gmail", "custom"})

_EMAIL_RE = re.compile(r"<([^<>]+@[^<>]+)>")
_NUMERIC_IDENTITY_RE = re.compile(r"^Identity #(\d+)$")
_INVALID_GPG_VALIDITY = frozenset({"r", "e", "d", "i"})


@dataclass(frozen=True)
class ImapConfig:
    host: str
    port: int
    username: str
    password: str
    safety: str = "SSL"
    auth: str = "PLAIN"
    interval_check_minutes: int = 5
    disconnected_mode: bool = True


@dataclass(frozen=True)
class SmtpConfig:
    host: str
    port: int
    username: str
    password: str
    encryption: str = "SSL"
    auth: str = "PLAIN"


@dataclass(frozen=True)
class GpgConfig:
    key: str = "auto"
    sign_by_default: bool = False
    encrypt_by_default: bool = False
    autocrypt: bool = False
    enable: bool = True


@dataclass(frozen=True)
class IdentitySpec:
    id: str
    name: str
    email: str
    real_name: str
    uoid: int
    transport_id: int
    disable_fcc: bool
    gpg: GpgConfig | None = field(default_factory=lambda: GpgConfig(key="auto"))
    smtp: SmtpConfig | None = None


@dataclass(frozen=True)
class AccountSpec:
    id: str
    name: str
    provider: str
    transport_id: int
    imap: ImapConfig
    smtp: SmtpConfig
    identity: IdentitySpec
    aliases: tuple[IdentitySpec, ...] = ()


@dataclass(frozen=True)
class ProvisionConfig:
    accounts: tuple[AccountSpec, ...]
    default_account_id: str
    default_identity_id: str
    default_transport_id: int
    default_identity_uoid: int
    default_identity_spec: IdentitySpec


def stable_transport_id(slug: str) -> int:
    digest = hashlib.sha256(f"kmail-provision:transport:{slug}".encode("utf-8")).hexdigest()
    return 100_000 + (int(digest[:8], 16) % 899_999_999)


def stable_identity_uoid(slug: str) -> int:
    digest = hashlib.sha256(f"kmail-provision:identity:{slug}".encode("utf-8")).hexdigest()
    return 100_000_000 + (int(digest[:8], 16) % 2_000_000_000)


def _normalize_password(password: str, provider: str) -> str:
    if provider == "gmail":
        return password.replace(" ", "")
    return password


def _validate_single_line(val: str, field_desc: str) -> str:
    if "\n" in val or "\r" in val:
        raise ConfigError(f"{field_desc} must not contain newline characters")
    return val.strip()


def _require_nonempty_str(obj: dict[str, Any], key: str, ctx: str) -> str:
    val = obj.get(key)
    if not isinstance(val, str) or not val.strip():
        raise ConfigError(f"{ctx}: missing or invalid string field '{key}'")
    return _validate_single_line(val, f"{ctx}.{key}")


def _parse_gpg(raw: Any, ctx: str, *, present: bool) -> GpgConfig | None:
    if not present:
        return GpgConfig(key="auto")
    if raw is None:
        return None
    if not isinstance(raw, dict):
        raise ConfigError(f"{ctx}.gpg must be an object or null")
    enable = raw.get("enable", True)
    if not isinstance(enable, bool):
        raise ConfigError(f"{ctx}.gpg.enable must be a boolean")
    if not enable:
        return GpgConfig(enable=False)
    key = raw.get("key", "auto")
    if not isinstance(key, str) or not key.strip():
        raise ConfigError(f"{ctx}.gpg.key must be 'auto' or a hex fingerprint")
    key = key.strip()
    if key.lower() != "auto":
        cleaned = key.replace(" ", "").upper()
        if not re.fullmatch(r"[0-9A-F]{16}|[0-9A-F]{40}", cleaned):
            raise ConfigError(
                f"{ctx}.gpg.key must be 'auto' or a 16/40-char hex fingerprint"
            )
        key = cleaned
    else:
        key = "auto"

    sign_by_default = raw.get("signByDefault", False)
    encrypt_by_default = raw.get("encryptByDefault", False)
    autocrypt = raw.get("autocrypt", False)
    for field_name, val in (
        ("signByDefault", sign_by_default),
        ("encryptByDefault", encrypt_by_default),
        ("autocrypt", autocrypt),
    ):
        if not isinstance(val, bool):
            raise ConfigError(f"{ctx}.gpg.{field_name} must be a boolean")
    return GpgConfig(
        key=key,
        sign_by_default=sign_by_default,
        encrypt_by_default=encrypt_by_default,
        autocrypt=autocrypt,
        enable=True,
    )


def _parse_smtp(
    raw_smtp: dict[str, Any],
    *,
    provider: str,
    default_email: str,
    default_password: str | None,
    ctx: str,
) -> SmtpConfig:
    if not isinstance(raw_smtp, dict):
        raise ConfigError(f"{ctx}.smtp must be an object")

    if provider == "gmail":
        host = raw_smtp.get("host", "smtp.gmail.com")
    else:
        host = raw_smtp.get("host")
    if not isinstance(host, str) or not host.strip():
        raise ConfigError(f"{ctx}: missing required field 'smtp.host'")
    host = _validate_single_line(host, f"{ctx}.smtp.host")

    port = raw_smtp.get("port", 465)
    if not isinstance(port, int) or isinstance(port, bool) or not (1 <= port <= 65535):
        raise ConfigError(f"{ctx}.smtp.port must be an integer 1..65535")

    username = raw_smtp.get("username", default_email)
    if not isinstance(username, str) or not username.strip():
        raise ConfigError(f"{ctx}.smtp.username must be a non-empty string")
    username = _validate_single_line(username, f"{ctx}.smtp.username")

    encryption = raw_smtp.get("encryption", "SSL")
    if not isinstance(encryption, str) or encryption not in VALID_SMTP_ENCRYPTION:
        raise ConfigError(
            f"{ctx}.smtp.encryption must be one of {sorted(VALID_SMTP_ENCRYPTION)}"
        )

    auth = raw_smtp.get("auth", "PLAIN")
    if not isinstance(auth, str) or auth not in VALID_SMTP_AUTH:
        raise ConfigError(
            f"{ctx}.smtp.auth must be one of {sorted(VALID_SMTP_AUTH)}"
        )

    raw_pw = raw_smtp.get("password", default_password)
    if not isinstance(raw_pw, str) or not raw_pw:
        raise ConfigError(f"{ctx}: missing password for SMTP")
    password = _normalize_password(raw_pw, provider)
    if not password:
        raise ConfigError(f"{ctx}: password for SMTP is empty after normalization")

    return SmtpConfig(
        host=host.strip(),
        port=port,
        username=username.strip(),
        password=password,
        encryption=encryption,
        auth=auth,
    )


def _parse_imap(
    raw_imap: dict[str, Any],
    *,
    provider: str,
    default_email: str,
    default_password: str | None,
    ctx: str,
) -> ImapConfig:
    if not isinstance(raw_imap, dict):
        raise ConfigError(f"{ctx}.imap must be an object")

    if provider == "gmail":
        host = raw_imap.get("host", "imap.gmail.com")
    else:
        host = raw_imap.get("host")
    if not isinstance(host, str) or not host.strip():
        raise ConfigError(f"{ctx}: missing required field 'imap.host'")
    host = _validate_single_line(host, f"{ctx}.imap.host")

    port = raw_imap.get("port", 993)
    if not isinstance(port, int) or isinstance(port, bool) or not (1 <= port <= 65535):
        raise ConfigError(f"{ctx}.imap.port must be an integer 1..65535")

    username = raw_imap.get("username", default_email)
    if not isinstance(username, str) or not username.strip():
        raise ConfigError(f"{ctx}.imap.username must be a non-empty string")
    username = _validate_single_line(username, f"{ctx}.imap.username")

    safety = raw_imap.get("safety", "SSL")
    if not isinstance(safety, str) or safety not in VALID_IMAP_SAFETY:
        raise ConfigError(
            f"{ctx}.imap.safety must be one of {sorted(VALID_IMAP_SAFETY)}"
        )

    auth = raw_imap.get("auth", "PLAIN")
    if not isinstance(auth, str) or auth not in VALID_IMAP_AUTH:
        raise ConfigError(
            f"{ctx}.imap.auth must be one of {sorted(VALID_IMAP_AUTH)}"
        )

    interval = raw_imap.get("intervalCheckMinutes", 5)
    if not isinstance(interval, int) or isinstance(interval, bool) or interval < 0:
        raise ConfigError(f"{ctx}.imap.intervalCheckMinutes must be a non-negative int")

    disconnected = raw_imap.get("disconnectedMode", True)
    if not isinstance(disconnected, bool):
        raise ConfigError(f"{ctx}.imap.disconnectedMode must be a boolean")

    raw_pw = raw_imap.get("password", default_password)
    if not isinstance(raw_pw, str) or not raw_pw:
        raise ConfigError(f"{ctx}: missing password for IMAP")
    password = _normalize_password(raw_pw, provider)
    if not password:
        raise ConfigError(f"{ctx}: password for IMAP is empty after normalization")

    return ImapConfig(
        host=host.strip(),
        port=port,
        username=username.strip(),
        password=password,
        safety=safety,
        auth=auth,
        interval_check_minutes=interval,
        disconnected_mode=disconnected,
    )


def _load_config_with_digest(path: Path) -> tuple[ProvisionConfig, str]:
    """Read, hash, validate, and expand presets from a declarative KMail JSON file."""
    try:
        raw_bytes = path.read_bytes()
    except OSError as exc:
        raise ConfigError(f"cannot read config file {path}: {exc}") from exc
    digest = hashlib.sha256(raw_bytes).hexdigest()
    try:
        raw = json.loads(raw_bytes.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ConfigError(f"invalid JSON in {path}: {exc}") from exc

    return _parse_config_dict(raw), digest


def load_config(path: Path) -> ProvisionConfig:
    """Load, validate, and expand presets from a declarative KMail JSON file."""
    cfg, _digest = _load_config_with_digest(path)
    return cfg


def _parse_config_dict(raw: Any) -> ProvisionConfig:
    if not isinstance(raw, dict):
        raise ConfigError("config root must be a JSON object")

    if raw.get("version") != 1:
        raise ConfigError("unsupported config version (expected integer 1)")

    raw_accounts = raw.get("accounts")
    if not isinstance(raw_accounts, list) or not raw_accounts:
        raise ConfigError("config must define a non-empty 'accounts' list")

    seen_slugs: set[str] = set()
    seen_transport_ids: dict[int, str] = {}
    seen_uoids: dict[int, str] = {}
    accounts_by_id: dict[str, AccountSpec] = {}
    identities_by_id: dict[str, IdentitySpec] = {}
    accounts: list[AccountSpec] = []

    def register_slug(slug: str, ctx: str) -> None:
        if slug in seen_slugs:
            raise ConfigError(f"{ctx}: duplicate id '{slug}'")
        seen_slugs.add(slug)

    def register_uoid(slug: str) -> int:
        uoid = stable_identity_uoid(slug)
        if uoid in seen_uoids:
            raise ConfigError(f"UOID hash collision between '{seen_uoids[uoid]}' and '{slug}'")
        seen_uoids[uoid] = slug
        return uoid

    def register_transport_id(slug: str) -> int:
        tid = stable_transport_id(slug)
        if tid in seen_transport_ids:
            raise ConfigError(
                f"transport ID hash collision between '{seen_transport_ids[tid]}' and '{slug}'"
            )
        seen_transport_ids[tid] = slug
        return tid

    for idx, acc_raw in enumerate(raw_accounts):
        ctx = f"accounts[{idx}]"
        if not isinstance(acc_raw, dict):
            raise ConfigError(f"{ctx} must be an object")

        slug = _require_nonempty_str(acc_raw, "id", ctx)
        register_slug(slug, ctx)
        name = _require_nonempty_str(acc_raw, "name", ctx)
        email = _require_nonempty_str(acc_raw, "email", ctx)
        real_name = _require_nonempty_str(acc_raw, "realName", ctx)

        provider = acc_raw.get("provider", "gmail")
        if not isinstance(provider, str) or provider not in VALID_PROVIDERS:
            raise ConfigError(
                f"{ctx}.provider must be one of {sorted(VALID_PROVIDERS)}"
            )

        shared_pw = acc_raw.get("password")
        if shared_pw is not None and not isinstance(shared_pw, str):
            raise ConfigError(f"{ctx}.password must be a string")

        imap = _parse_imap(
            acc_raw.get("imap", {}),
            provider=provider,
            default_email=email,
            default_password=shared_pw,
            ctx=ctx,
        )
        smtp = _parse_smtp(
            acc_raw.get("smtp", {}),
            provider=provider,
            default_email=email,
            default_password=shared_pw,
            ctx=ctx,
        )

        default_disable_fcc = provider == "gmail"
        disable_fcc = acc_raw.get("disableFcc", default_disable_fcc)
        if not isinstance(disable_fcc, bool):
            raise ConfigError(f"{ctx}.disableFcc must be a boolean")

        gpg = _parse_gpg(acc_raw.get("gpg"), ctx, present="gpg" in acc_raw)
        transport_id = register_transport_id(slug)
        identity_uoid = register_uoid(slug)
        primary_identity = IdentitySpec(
            id=slug,
            name=name,
            email=email,
            real_name=real_name,
            uoid=identity_uoid,
            transport_id=transport_id,
            disable_fcc=disable_fcc,
            gpg=gpg,
            smtp=None,
        )
        identities_by_id[slug] = primary_identity

        raw_aliases = acc_raw.get("aliases", [])
        if not isinstance(raw_aliases, list):
            raise ConfigError(f"{ctx}.aliases must be a list")

        aliases: list[IdentitySpec] = []
        for a_idx, alias_raw in enumerate(raw_aliases):
            actx = f"{ctx}.aliases[{a_idx}]"
            if not isinstance(alias_raw, dict):
                raise ConfigError(f"{actx} must be an object")
            a_slug = _require_nonempty_str(alias_raw, "id", actx)
            register_slug(a_slug, actx)
            a_name = _require_nonempty_str(alias_raw, "name", actx)
            a_email = _require_nonempty_str(alias_raw, "email", actx)
            a_real_name = _require_nonempty_str(alias_raw, "realName", actx)

            a_disable_fcc = alias_raw.get("disableFcc", disable_fcc)
            if not isinstance(a_disable_fcc, bool):
                raise ConfigError(f"{actx}.disableFcc must be a boolean")

            a_gpg = _parse_gpg(alias_raw.get("gpg"), actx, present="gpg" in alias_raw)
            a_uoid = register_uoid(a_slug)

            if "smtp" in alias_raw and alias_raw["smtp"] is not None:
                a_smtp = _parse_smtp(
                    alias_raw["smtp"],
                    provider="custom",
                    default_email=a_email,
                    default_password=shared_pw,
                    ctx=actx,
                )
                a_tid = register_transport_id(a_slug)
            else:
                a_smtp = None
                a_tid = transport_id

            alias_spec = IdentitySpec(
                id=a_slug,
                name=a_name,
                email=a_email,
                real_name=a_real_name,
                uoid=a_uoid,
                transport_id=a_tid,
                disable_fcc=a_disable_fcc,
                gpg=a_gpg,
                smtp=a_smtp,
            )
            aliases.append(alias_spec)
            identities_by_id[a_slug] = alias_spec

        account = AccountSpec(
            id=slug,
            name=name,
            provider=provider,
            transport_id=transport_id,
            imap=imap,
            smtp=smtp,
            identity=primary_identity,
            aliases=tuple(aliases),
        )
        accounts.append(account)
        accounts_by_id[slug] = account

    default_account_id = raw.get("defaultAccount", accounts[0].id)
    if not isinstance(default_account_id, str) or default_account_id not in accounts_by_id:
        raise ConfigError(
            "defaultAccount must be a string matching an account id"
        )

    default_identity_id = raw.get("defaultIdentity", default_account_id)
    if not isinstance(default_identity_id, str) or default_identity_id not in identities_by_id:
        raise ConfigError(
            "defaultIdentity must be a string matching an account or alias id"
        )

    default_account = accounts_by_id[default_account_id]
    default_identity = identities_by_id[default_identity_id]

    return ProvisionConfig(
        accounts=tuple(accounts),
        default_account_id=default_account_id,
        default_identity_id=default_identity_id,
        default_transport_id=default_account.transport_id,
        default_identity_uoid=default_identity.uoid,
        default_identity_spec=default_identity,
    )


def _default_gpg_runner(args: list[str]) -> str | None:
    try:
        res = subprocess.run(
            args,
            capture_output=True,
            text=True,
            check=False,
            timeout=10,
        )
    except (subprocess.TimeoutExpired, OSError) as exc:
        LOG.warning("gpg command failed while resolving keys: %s", exc)
        return None
    if res.returncode != 0:
        LOG.warning("gpg command exited %d while resolving keys", res.returncode)
        return None
    return res.stdout


def resolve_gpg_fingerprint(
    email: str,
    gpg_cfg: GpgConfig | None,
    gpg_runner: Callable[[list[str]], str | None] | None = None,
) -> str | None:
    """Resolve the GPG fingerprint to bind to an identity.

    Raises GpgLookupError when the gpg command itself fails transiently so callers
    preserve existing bindings instead of clearing them.
    """
    if gpg_cfg is None or not gpg_cfg.enable:
        return None
    if gpg_cfg.key != "auto":
        return gpg_cfg.key.upper()

    runner = gpg_runner or _default_gpg_runner
    output = runner(["gpg", "--list-secret-keys", "--with-colons"])
    if output is None:
        raise GpgLookupError("gpg --list-secret-keys failed")
    if not output:
        return None

    target = email.strip().lower()
    matched_fprs: list[str] = []

    current_sec_valid = False
    current_primary_fpr: str | None = None
    in_subkey = False
    current_matched = False

    for line in output.splitlines():
        fields = line.split(":")
        if not fields:
            continue
        rec = fields[0]
        if rec == "sec":
            validity = fields[1] if len(fields) > 1 else ""
            current_sec_valid = validity not in _INVALID_GPG_VALIDITY
            current_primary_fpr = None
            in_subkey = False
            current_matched = False
        elif rec == "ssb":
            in_subkey = True
        elif rec == "fpr" and not in_subkey and current_primary_fpr is None:
            if len(fields) > 9 and fields[9]:
                current_primary_fpr = fields[9].strip().upper()
        elif rec == "uid" and current_sec_valid and current_primary_fpr and not current_matched:
            uid_validity = fields[1] if len(fields) > 1 else ""
            if uid_validity in _INVALID_GPG_VALIDITY:
                continue
            uid_text = fields[9] if len(fields) > 9 else ""
            match = _EMAIL_RE.search(uid_text)
            uid_email = match.group(1).strip().lower() if match else uid_text.strip().lower()
            if uid_email == target:
                matched_fprs.append(current_primary_fpr)
                current_matched = True

    if len(matched_fprs) == 1:
        return matched_fprs[0]
    if len(matched_fprs) > 1:
        LOG.warning(
            "Multiple (%d) valid GPG secret keys match %s; skipping auto-bind (set gpg.key explicitly)",
            len(matched_fprs),
            email,
        )
    return None


# ---------------------------------------------------------------------------
# Line-preserving KConfig INI helper
# ---------------------------------------------------------------------------


@dataclass
class _KConfigSection:
    name: str
    lines: list[str] = field(default_factory=list)


class KConfigFile:
    """Line-preserving KConfig reader/writer that preserves key casing, comments, and [$e] suffixes."""

    def __init__(
        self,
        preamble: list[str] | None = None,
        sections: list[_KConfigSection] | None = None,
    ) -> None:
        self._preamble: list[str] = list(preamble or [])
        self._sections: list[_KConfigSection] = list(sections or [])

    @classmethod
    def load(cls, path: Path) -> KConfigFile:
        if not path.exists():
            return cls()
        text = path.read_text(encoding="utf-8")
        preamble: list[str] = []
        sections: list[_KConfigSection] = []
        current: _KConfigSection | None = None

        for raw_line in text.splitlines():
            stripped = raw_line.strip()
            if stripped.startswith("[") and stripped.endswith("]") and len(stripped) >= 2:
                group_name = stripped[1:-1]
                current = _KConfigSection(name=group_name)
                sections.append(current)
            elif current is None:
                preamble.append(raw_line)
            else:
                current.lines.append(raw_line)

        return cls(preamble=preamble, sections=sections)

    def _find_section(self, group: str) -> _KConfigSection | None:
        for sec in self._sections:
            if sec.name == group:
                return sec
        return None

    def groups(self) -> list[str]:
        return [sec.name for sec in self._sections]

    def get(self, group: str, key: str, default: str | None = None) -> str | None:
        sec = self._find_section(group)
        if sec is None:
            return default
        prefix = f"{key}="
        for line in sec.lines:
            if line.startswith(prefix):
                return line[len(prefix) :]
        return default

    def set(self, group: str, key: str, value: str) -> bool:
        sec = self._find_section(group)
        new_line = f"{key}={value}"
        if sec is None:
            sec = _KConfigSection(name=group, lines=[new_line])
            self._sections.append(sec)
            return True

        prefix = f"{key}="
        for idx, line in enumerate(sec.lines):
            if line.startswith(prefix):
                if line == new_line:
                    return False
                sec.lines[idx] = new_line
                return True

        # Insert before trailing blank lines so formatting stays clean
        insert_at = len(sec.lines)
        while insert_at > 0 and sec.lines[insert_at - 1].strip() == "":
            insert_at -= 1
        sec.lines.insert(insert_at, new_line)
        return True

    def remove_key(self, group: str, key: str) -> bool:
        sec = self._find_section(group)
        if sec is None:
            return False
        prefix = f"{key}="
        new_lines = [line for line in sec.lines if not line.startswith(prefix)]
        if len(new_lines) == len(sec.lines):
            return False
        sec.lines = new_lines
        return True

    def remove_group(self, group: str) -> bool:
        before = len(self._sections)
        self._sections = [sec for sec in self._sections if sec.name != group]
        return len(self._sections) != before

    def rename_group(self, old_name: str, new_name: str) -> bool:
        sec = self._find_section(old_name)
        if sec is None or old_name == new_name:
            return False
        sec.name = new_name
        return True

    def dumps(self) -> str:
        out: list[str] = []
        if self._preamble:
            out.extend(self._preamble)
        for idx, sec in enumerate(self._sections):
            if out and out[-1].strip() != "":
                out.append("")
            out.append(f"[{sec.name}]")
            lines = list(sec.lines)
            while lines and lines[-1].strip() == "":
                lines.pop()
            out.extend(lines)
            if idx < len(self._sections) - 1:
                out.append("")
        return ("\n".join(out) + "\n") if out else ""

    def save_atomic(self, path: Path) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        content = self.dumps()
        fd, tmp_name = tempfile.mkstemp(
            prefix=f".{path.name}.", suffix=".tmp", dir=str(path.parent)
        )
        try:
            os.fchmod(fd, 0o600)
            with os.fdopen(fd, "w", encoding="utf-8") as fh:
                fh.write(content)
            os.replace(tmp_name, path)
        except BaseException:
            try:
                os.unlink(tmp_name)
            except OSError:
                pass
            raise


# ---------------------------------------------------------------------------
# State store (IDs only — never passwords or email addresses)
# ---------------------------------------------------------------------------


class StateStore:
    """Persists managed account/resource/transport/identity IDs (mode 0600, zero secrets)."""

    @staticmethod
    def load(path: Path) -> dict[str, Any]:
        if not path.exists():
            return {"version": 1, "managed": {}}
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            LOG.warning("State file %s unreadable (%s); starting fresh", path, exc)
            return {"version": 1, "managed": {}}
        if not isinstance(data, dict) or not isinstance(data.get("managed"), dict):
            return {"version": 1, "managed": {}}
        return data

    @staticmethod
    def save(path: Path, state: dict[str, Any]) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        payload = json.dumps(state, indent=2, sort_keys=True) + "\n"
        fd, tmp_name = tempfile.mkstemp(
            prefix=f".{path.name}.", suffix=".tmp", dir=str(path.parent)
        )
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


# ---------------------------------------------------------------------------
# Akonadi D-Bus & QtKeychain adapters
# ---------------------------------------------------------------------------


class AkonadiProtocol(Protocol):
    def is_ready(self, timeout: int = 5) -> bool: ...
    def ensure_ready(self, wait_seconds: int) -> None: ...
    def list_imap_resources(self) -> list[str]: ...
    def get_imap_settings(self, resource_id: str) -> dict[str, Any]: ...
    def wait_for_resource_settings(self, resource_id: str, wait_seconds: int) -> None: ...
    def create_imap_resource(
        self,
        wait_seconds: int,
        on_created: Callable[[str], None] | None = None,
    ) -> str: ...
    def apply_imap_settings(self, resource_id: str, settings: dict[str, Any]) -> None: ...
    def restart_resource(self, resource_id: str, wait_seconds: int = 30) -> None: ...
    def remove_resource(self, resource_id: str) -> None: ...


class KeychainProtocol(Protocol):
    def ensure_ready(self, wait_seconds: int) -> None: ...
    def set_password(self, service: str, key: str, password: str) -> bool: ...


def _run_qdbus(*args: str, timeout: int = 10) -> subprocess.CompletedProcess[str]:
    cmd = ["qdbus", *args]
    try:
        return subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            check=False,
            timeout=timeout,
        )
    except (subprocess.TimeoutExpired, OSError) as exc:
        return subprocess.CompletedProcess(
            args=cmd,
            returncode=124,
            stdout="",
            stderr=str(exc),
        )


def _parse_qdbus_bool(raw: str) -> bool:
    return raw.strip().lower() == "true"


class AkonadiClient:
    """Thin D-Bus client for Akonadi Control and akonadi_imap_resource /Settings."""

    _CONTROL = "org.freedesktop.Akonadi.Control"
    _AGENT_MGR_PATH = "/AgentManager"
    _AGENT_MGR_IFACE = "org.freedesktop.Akonadi.AgentManager"
    _IMAP_IFACE = "org.kde.Akonadi.Imap.Settings"

    def _control_ready(self, timeout: int = 10) -> bool:
        res = _run_qdbus(
            self._CONTROL,
            self._AGENT_MGR_PATH,
            f"{self._AGENT_MGR_IFACE}.agentInstances",
            timeout=timeout,
        )
        return res.returncode == 0

    def is_ready(self, timeout: int = 5) -> bool:
        """Non-mutating check for whether Akonadi Control is already running."""
        return self._control_ready(timeout=timeout)

    def ensure_ready(self, wait_seconds: int) -> None:
        deadline = time.monotonic() + max(wait_seconds, 1)
        remaining = max(1, min(10, int(deadline - time.monotonic()) + 1))
        if self._control_ready(timeout=remaining):
            return
        LOG.info("Akonadi not running; starting via akonadictl start")
        start_timeout = max(1, min(15, int(max(deadline - time.monotonic(), 1))))
        try:
            subprocess.run(
                ["akonadictl", "start"],
                capture_output=True,
                text=True,
                check=False,
                timeout=start_timeout,
            )
        except (subprocess.TimeoutExpired, OSError) as exc:
            LOG.warning("akonadictl start failed or timed out: %s", exc)
        while True:
            rem = deadline - time.monotonic()
            if rem <= 0:
                break
            if self._control_ready(timeout=max(1, min(10, int(rem) + 1))):
                return
            if time.monotonic() >= deadline:
                break
            time.sleep(min(0.5, max(0.05, deadline - time.monotonic())))
        raise SessionNotReadyError(
            f"Akonadi Control D-Bus service unavailable after {wait_seconds}s"
        )

    def _call_agent_mgr(self, method: str, *args: str) -> str:
        res = _run_qdbus(
            self._CONTROL, self._AGENT_MGR_PATH, f"{self._AGENT_MGR_IFACE}.{method}", *args
        )
        if res.returncode == 124:
            raise SessionNotReadyError(
                f"Akonadi AgentManager.{method} timed out or unavailable: {res.stderr.strip()}"
            )
        if res.returncode != 0:
            raise ProvisionError(
                f"Akonadi AgentManager.{method} failed: {res.stderr.strip()}"
            )
        return res.stdout.strip()

    def list_imap_resources(self) -> list[str]:
        out = self._call_agent_mgr("agentInstances")
        instances = [line.strip() for line in out.splitlines() if line.strip()]
        imap_ids: list[str] = []
        for inst in instances:
            atype = self._call_agent_mgr("agentInstanceType", inst)
            if atype == "akonadi_imap_resource":
                imap_ids.append(inst)
        return imap_ids

    def _get_setting(self, resource_id: str, getter: str) -> str:
        res = _run_qdbus(
            f"org.freedesktop.Akonadi.Resource.{resource_id}",
            "/Settings",
            f"{self._IMAP_IFACE}.{getter}",
        )
        if res.returncode == 124:
            raise SessionNotReadyError(
                f"Akonadi {resource_id} /Settings.{getter} timed out: {res.stderr.strip()}"
            )
        if res.returncode != 0:
            raise ProvisionError(
                f"Akonadi {resource_id} /Settings.{getter} failed: {res.stderr.strip()}"
            )
        return res.stdout.strip()

    def _set_setting(self, resource_id: str, setter: str, *args: str) -> None:
        res = _run_qdbus(
            f"org.freedesktop.Akonadi.Resource.{resource_id}",
            "/Settings",
            f"{self._IMAP_IFACE}.{setter}",
            *args,
        )
        if res.returncode == 124:
            raise SessionNotReadyError(
                f"Akonadi {resource_id} /Settings.{setter} timed out: {res.stderr.strip()}"
            )
        if res.returncode != 0:
            raise ProvisionError(
                f"Akonadi {resource_id} /Settings.{setter} failed: {res.stderr.strip()}"
            )

    def get_imap_settings(self, resource_id: str) -> dict[str, Any]:
        return {
            "name": self._get_setting(resource_id, "name"),
            "imapServer": self._get_setting(resource_id, "imapServer"),
            "imapPort": int(self._get_setting(resource_id, "imapPort") or "993"),
            "userName": self._get_setting(resource_id, "userName"),
            "safety": self._get_setting(resource_id, "safety"),
            "authentication": int(self._get_setting(resource_id, "authentication") or "7"),
            "intervalCheckEnabled": _parse_qdbus_bool(
                self._get_setting(resource_id, "intervalCheckEnabled")
            ),
            "intervalCheckTime": int(
                self._get_setting(resource_id, "intervalCheckTime") or "5"
            ),
            "disconnectedModeEnabled": _parse_qdbus_bool(
                self._get_setting(resource_id, "disconnectedModeEnabled")
            ),
            "useDefaultIdentity": _parse_qdbus_bool(
                self._get_setting(resource_id, "useDefaultIdentity")
            ),
            "accountIdentity": int(self._get_setting(resource_id, "accountIdentity") or "0"),
        }

    def wait_for_resource_settings(self, resource_id: str, wait_seconds: int) -> None:
        deadline = time.monotonic() + max(wait_seconds, 1)
        while True:
            rem = deadline - time.monotonic()
            if rem <= 0:
                break
            probe = _run_qdbus(
                f"org.freedesktop.Akonadi.Resource.{resource_id}",
                "/Settings",
                f"{self._IMAP_IFACE}.imapServer",
                timeout=max(1, min(10, int(rem) + 1)),
            )
            if probe.returncode == 0:
                return
            if time.monotonic() >= deadline:
                break
            time.sleep(min(0.5, max(0.05, deadline - time.monotonic())))
        raise SessionNotReadyError(
            f"Akonadi resource {resource_id} /Settings unavailable after {wait_seconds}s"
        )

    def create_imap_resource(
        self,
        wait_seconds: int,
        on_created: Callable[[str], None] | None = None,
    ) -> str:
        res_id = self._call_agent_mgr("createAgentInstance", "akonadi_imap_resource")
        if not res_id:
            raise ProvisionError("Akonadi createAgentInstance returned empty identifier")
        if on_created is not None:
            on_created(res_id)
        self.wait_for_resource_settings(res_id, wait_seconds)
        return res_id

    def apply_imap_settings(self, resource_id: str, settings: dict[str, Any]) -> None:
        setter_map: list[tuple[str, str]] = [
            ("name", "setName"),
            ("imapServer", "setImapServer"),
            ("imapPort", "setImapPort"),
            ("userName", "setUserName"),
            ("safety", "setSafety"),
            ("authentication", "setAuthentication"),
            ("intervalCheckEnabled", "setIntervalCheckEnabled"),
            ("intervalCheckTime", "setIntervalCheckTime"),
            ("disconnectedModeEnabled", "setDisconnectedModeEnabled"),
            ("useDefaultIdentity", "setUseDefaultIdentity"),
            ("accountIdentity", "setAccountIdentity"),
        ]
        for key, setter in setter_map:
            if key not in settings:
                continue
            val = settings[key]
            if isinstance(val, bool):
                arg = "true" if val else "false"
            else:
                arg = str(val)
            self._set_setting(resource_id, setter, arg)
        self._set_setting(resource_id, "save")

    def _get_resource_dbus_owner(self, resource_id: str, timeout: int = 5) -> str | None:
        res = _run_qdbus(
            "org.freedesktop.DBus",
            "/org/freedesktop/DBus",
            "org.freedesktop.DBus.GetNameOwner",
            f"org.freedesktop.Akonadi.Resource.{resource_id}",
            timeout=timeout,
        )
        if res.returncode != 0:
            return None
        owner = res.stdout.strip()
        return owner or None

    def _get_agent_status(self, resource_id: str, timeout: int = 5) -> int | None:
        res = _run_qdbus(
            self._CONTROL,
            self._AGENT_MGR_PATH,
            f"{self._AGENT_MGR_IFACE}.agentInstanceStatus",
            resource_id,
            timeout=timeout,
        )
        if res.returncode != 0:
            return None
        raw = res.stdout.strip()
        try:
            return int(raw)
        except ValueError:
            return None

    def restart_resource(self, resource_id: str, wait_seconds: int = 30) -> None:
        # Akonadi's AgentProcessInstance::restartWhenIdle() silently ignores
        # restartAgentInstance() when status() == 1 (Running/busy). Wait until
        # the resource is idle and confirm a new D-Bus unique owner takes over.
        deadline = time.monotonic() + max(wait_seconds, 1)
        owner_before = self._get_resource_dbus_owner(
            resource_id, timeout=min(5, max(1, wait_seconds))
        )
        restart_requested = False
        last_restart_at = 0.0

        while True:
            rem = deadline - time.monotonic()
            if rem <= 0:
                break
            step_timeout = max(1, min(5, int(rem) + 1))

            owner_now: str | None = None
            if restart_requested:
                owner_now = self._get_resource_dbus_owner(resource_id, timeout=step_timeout)
                if owner_before is not None:
                    if owner_now is not None and owner_now != owner_before:
                        return
                elif owner_now is not None:
                    return

            status = self._get_agent_status(resource_id, timeout=step_timeout)
            if status != 1:
                now = time.monotonic()
                if not restart_requested or (
                    now - last_restart_at >= 1.5
                    and (owner_before is None or owner_now == owner_before)
                ):
                    self._call_agent_mgr("restartAgentInstance", resource_id)
                    restart_requested = True
                    last_restart_at = time.monotonic()

            if time.monotonic() >= deadline:
                break
            time.sleep(min(0.25, max(0.05, deadline - time.monotonic())))

        raise SessionNotReadyError(
            f"Akonadi resource {resource_id} did not restart within {wait_seconds}s"
        )

    def remove_resource(self, resource_id: str) -> None:
        self._call_agent_mgr("removeAgentInstance", resource_id)


class KeychainClient:
    """QtKeychain adapter invoking kmail-keychain-set with password passed strictly via stdin."""

    def __init__(self, helper_bin: str = "kmail-keychain-set") -> None:
        self._helper_bin = helper_bin

    @staticmethod
    def _prefer_kwallet() -> bool:
        backend = os.environ.get("QTKEYCHAIN_BACKEND", "").strip().lower()
        if backend == "kwallet":
            return True
        if backend in ("secretservice", "libsecret", "gnome"):
            return False
        if os.environ.get("KDE_FULL_SESSION"):
            return True
        desktop = os.environ.get("XDG_CURRENT_DESKTOP", "").upper()
        return "KDE" in desktop

    @classmethod
    def _kwallet_ready(cls, timeout: int = 10) -> tuple[bool, bool]:
        """Return (kwallet_service_present, network_wallet_is_open)."""
        wallet = _run_qdbus(
            "org.kde.kwalletd6",
            "/modules/kwalletd6",
            "org.kde.KWallet.networkWallet",
            timeout=timeout,
        )
        wallet_name = wallet.stdout.strip()
        if wallet.returncode != 0 or not wallet_name:
            return False, False
        opened = _run_qdbus(
            "org.kde.kwalletd6",
            "/modules/kwalletd6",
            "org.kde.KWallet.isOpen",
            wallet_name,
            timeout=timeout,
        )
        return True, (opened.returncode == 0 and opened.stdout.strip().lower() == "true")

    @staticmethod
    def _freedesktop_secrets_ready(timeout: int = 10) -> bool:
        locked = _run_qdbus(
            "org.freedesktop.secrets",
            "/org/freedesktop/secrets/aliases/default",
            "org.freedesktop.DBus.Properties.Get",
            "org.freedesktop.Secret.Collection",
            "Locked",
            timeout=timeout,
        )
        return locked.returncode == 0 and locked.stdout.strip().lower() == "false"

    @classmethod
    def _secret_service_ready(cls, timeout: int = 10) -> bool:
        if cls._prefer_kwallet():
            present, is_open = cls._kwallet_ready(timeout=timeout)
            if present:
                return is_open
            return cls._freedesktop_secrets_ready(timeout=timeout)
        if cls._freedesktop_secrets_ready(timeout=timeout):
            return True
        _, is_open = cls._kwallet_ready(timeout=timeout)
        return is_open

    def ensure_ready(self, wait_seconds: int) -> None:
        deadline = time.monotonic() + max(wait_seconds, 1)
        while True:
            rem = deadline - time.monotonic()
            if self._secret_service_ready(timeout=max(1, min(10, int(max(rem, 1))))):
                return
            if time.monotonic() >= deadline:
                break
            time.sleep(min(0.5, max(0.05, deadline - time.monotonic())))
        raise SessionNotReadyError(
            f"Secret Service / KWallet locked or unavailable after {wait_seconds}s"
        )

    def set_password(self, service: str, key: str, password: str) -> bool:
        try:
            res = subprocess.run(
                [self._helper_bin, service, key],
                input=password,
                capture_output=True,
                text=True,
                check=False,
                timeout=15,
            )
        except (subprocess.TimeoutExpired, OSError) as exc:
            raise SessionNotReadyError(
                f"Keychain helper timed out or unavailable for ({service}, {key}): {type(exc).__name__}"
            ) from exc
        if res.returncode == 3:
            err = res.stderr.strip() or "keychain backend unavailable or locked"
            raise SessionNotReadyError(
                f"Keychain unavailable for ({service}, {key}): {err}"
            )
        if res.returncode != 0:
            err = res.stderr.strip() or f"exit status {res.returncode}"
            raise ProvisionError(f"kmail-keychain-set failed for ({service}, {key}): {err}")
        return res.stdout.strip() == "updated"


# ---------------------------------------------------------------------------
# Reconcilers
# ---------------------------------------------------------------------------


def _bool_str(val: bool) -> str:
    return "true" if val else "false"


def _iter_managed_transports(cfg: ProvisionConfig) -> list[tuple[str, str, int, SmtpConfig]]:
    result: list[tuple[str, str, int, SmtpConfig]] = []
    for acc in cfg.accounts:
        result.append((acc.id, acc.name, acc.transport_id, acc.smtp))
        for alias in acc.aliases:
            if alias.smtp is not None:
                result.append((alias.id, alias.name, alias.transport_id, alias.smtp))
    return result


def _iter_managed_identities(cfg: ProvisionConfig) -> list[IdentitySpec]:
    result: list[IdentitySpec] = []
    for acc in cfg.accounts:
        result.append(acc.identity)
        result.extend(acc.aliases)
    return result


def _file_stat_sig(path: Path) -> tuple[int, int, int, int] | None:
    try:
        st = path.stat()
        return (st.st_dev, st.st_ino, st.st_mtime_ns, st.st_size)
    except FileNotFoundError:
        return None


def reconcile_mailtransports(
    cfg: ProvisionConfig,
    config_dir: Path,
    state: dict[str, Any],
    keychain: KeychainProtocol,
    dry_run: bool,
    prune: bool,
) -> list[str]:
    actions: list[str] = []
    mt_path = config_dir / "mailtransports"
    desired_transports = _iter_managed_transports(cfg)
    desired_tids = {tid for _, _, tid, _ in desired_transports}

    # Write wallet secrets BEFORE reading/merging mailtransports so manual edits
    # made while wallet calls are pending are never overwritten by a stale snapshot.
    for _slug, _name, tid, smtp in desired_transports:
        if dry_run:
            actions.append(f"keychain: ensure password for (mailtransports, {tid}) [redacted]")
        else:
            if keychain.set_password("mailtransports", str(tid), smtp.password):
                actions.append(f"keychain: updated password for (mailtransports, {tid})")

    prev_tids: set[int] = set()
    if prune:
        for entry in state.get("managed", {}).values():
            if isinstance(entry.get("transport_id"), int):
                prev_tids.add(entry["transport_id"])
            for alias_entry in entry.get("aliases", {}).values():
                if isinstance(alias_entry.get("transport_id"), int):
                    prev_tids.add(alias_entry["transport_id"])
        for retired_tid in state.get("retired_transport_ids", []):
            if isinstance(retired_tid, int):
                prev_tids.add(retired_tid)

    max_merge_attempts = 1 if dry_run else 5
    for _attempt in range(max_merge_attempts):
        stat_before = _file_stat_sig(mt_path)
        kc = KConfigFile.load(mt_path)
        changed = False
        file_actions: list[str] = []

        if kc.set("General", "default", str(cfg.default_transport_id)):
            changed = True
            file_actions.append(f"mailtransports: set General.default={cfg.default_transport_id}")

        for slug, name, tid, smtp in desired_transports:
            grp = f"Transport {tid}"
            fields = {
                "id": str(tid),
                "name": name,
                "identifier": "SMTP",
                "host": smtp.host,
                "port": str(smtp.port),
                "user": smtp.username,
                "auth": "true",
                "storepass": "true",
                "encryption": smtp.encryption,
                "authtype": smtp.auth,
            }
            grp_changed = False
            for k, v in fields.items():
                if kc.set(grp, k, v):
                    grp_changed = True
                    changed = True
            if grp_changed:
                file_actions.append(
                    f"mailtransports: upsert {grp} ({slug}: {smtp.host}:{smtp.port})"
                )

        if prune:
            for old_tid in sorted(prev_tids - desired_tids):
                if kc.remove_group(f"Transport {old_tid}"):
                    changed = True
                    file_actions.append(f"mailtransports: pruned Transport {old_tid}")

        if dry_run or not changed:
            actions.extend(file_actions)
            break

        if _file_stat_sig(mt_path) != stat_before:
            continue

        kc.save_atomic(mt_path)
        actions.extend(file_actions)
        break
    else:
        raise SessionNotReadyError(
            "mailtransports changed concurrently across merge retries; retrying later"
        )

    return actions


def _numeric_identity_groups(kc: KConfigFile) -> list[tuple[int, str]]:
    """Return (index, group_name) for numeric KIdentityManagement groups only."""
    found: list[tuple[int, str]] = []
    for grp in kc.groups():
        m = _NUMERIC_IDENTITY_RE.match(grp)
        if m:
            found.append((int(m.group(1)), grp))
    return found


_FIRSTRUN_ALLOWED_KEYS = frozenset(
    {
        "Default Domain",
        "Disable Fcc",
        "Disable Spam",
        "Email Address",
        "Identity",
        "Image Location",
        "Inline Signature",
        "Name",
        "Override Encryption Defaults",
        "Signature Enabled",
        "uoid",
    }
)


def _is_firstrun_placeholder_identity(
    kc: KConfigFile, grp: str, default_uoid: str | None
) -> bool:
    """Positively identify KDE's autogenerated blank first-run identity.

    Preserves any identity that is not the current default or carries any user
    customization (signature, reply-to, organization, transport, PGP keys, etc.).
    """
    uoid = (kc.get(grp, "uoid") or "").strip()
    if not default_uoid or uoid != default_uoid:
        return False
    if (kc.get(grp, "Email Address") or "").strip():
        return False
    if (kc.get(grp, "Default Domain") or "").strip() == "":
        return False

    sec = kc._find_section(grp)
    if sec is None:
        return False
    for line in sec.lines:
        stripped = line.strip()
        if not stripped or stripped.startswith("#") or "=" not in stripped:
            continue
        k, v = stripped.split("=", 1)
        if k not in _FIRSTRUN_ALLOWED_KEYS:
            return False
        if k in ("Image Location", "Inline Signature") and v.strip():
            return False
        if k in ("Disable Fcc", "Disable Spam", "Override Encryption Defaults", "Signature Enabled"):
            if v.strip().lower() != "false":
                return False
    return True


def reconcile_emailidentities(
    cfg: ProvisionConfig,
    config_dir: Path,
    state: dict[str, Any],
    gpg_runner: Callable[[list[str]], str | None] | None,
    dry_run: bool,
    prune: bool,
) -> tuple[list[str], dict[str, int]]:
    actions: list[str] = []
    ei_path = config_dir / "emailidentities"
    kc = KConfigFile.load(ei_path)
    changed = False

    desired_identities = _iter_managed_identities(cfg)
    desired_uoids = {ident.uoid for ident in desired_identities}

    # Remove only when the file contains solely KDE's untouched first-run placeholder identity
    numeric_groups = _numeric_identity_groups(kc)
    default_uoid = (kc.get("General", "Default Identity") or "").strip() or None
    if len(numeric_groups) == 1:
        _idx, grp = numeric_groups[0]
        if _is_firstrun_placeholder_identity(kc, grp, default_uoid):
            kc.remove_group(grp)
            changed = True
            actions.append(f"emailidentities: removed blank default {grp}")

    if prune:
        prev_uoids: set[int] = set()
        for entry in state.get("managed", {}).values():
            if isinstance(entry.get("identity_uoid"), int):
                prev_uoids.add(entry["identity_uoid"])
            for alias_entry in entry.get("aliases", {}).values():
                if isinstance(alias_entry.get("identity_uoid"), int):
                    prev_uoids.add(alias_entry["identity_uoid"])
        to_remove = prev_uoids - desired_uoids
        for _idx, grp in list(_numeric_identity_groups(kc)):
            raw_uoid = kc.get(grp, "uoid")
            if raw_uoid and raw_uoid.isdigit() and int(raw_uoid) in to_remove:
                kc.remove_group(grp)
                changed = True
                actions.append(f"emailidentities: pruned {grp} (uoid={raw_uoid})")

    # Map existing numeric groups (leaving existing indices and non-numeric groups untouched)
    uoid_to_group: dict[int, str] = {}
    used_indices: set[int] = set()
    for idx, grp in _numeric_identity_groups(kc):
        used_indices.add(idx)
        raw_uoid = kc.get(grp, "uoid")
        if raw_uoid and raw_uoid.isdigit():
            uoid_to_group[int(raw_uoid)] = grp

    def allocate_identity_group() -> str:
        idx = 0
        while idx in used_indices:
            idx += 1
        used_indices.add(idx)
        return f"Identity #{idx}"

    if kc.set("General", "Default Identity", str(cfg.default_identity_uoid)):
        changed = True
        actions.append(
            f"emailidentities: set General.Default Identity={cfg.default_identity_uoid}"
        )

    slug_to_uoid: dict[str, int] = {}
    for ident in desired_identities:
        slug_to_uoid[ident.id] = ident.uoid
        grp = uoid_to_group.get(ident.uoid)
        if grp is None:
            grp = allocate_identity_group()
            uoid_to_group[ident.uoid] = grp

        existing_email = (kc.get(grp, "Email Address") or "").strip().lower()
        address_matches_existing = bool(existing_email) and existing_email == ident.email.lower()

        gpg_lookup_failed = False
        fpr: str | None = None
        try:
            fpr = resolve_gpg_fingerprint(ident.email, ident.gpg, gpg_runner=gpg_runner)
        except GpgLookupError:
            gpg_lookup_failed = True
            if address_matches_existing:
                LOG.warning(
                    "GPG key lookup failed for %s; preserving existing PGP settings",
                    ident.id,
                )
            else:
                LOG.warning(
                    "GPG key lookup failed for %s after email change; clearing stale PGP binding",
                    ident.id,
                )

        preserve_existing_gpg = gpg_lookup_failed and address_matches_existing

        base_fields: dict[str, str] = {
            "Identity": ident.name,
            "Name": ident.real_name,
            "Email Address": ident.email,
            "Transport": str(ident.transport_id),
            "Disable Fcc": _bool_str(ident.disable_fcc),
            "uoid": str(ident.uoid),
        }
        if not preserve_existing_gpg:
            override_encryption_defaults = bool(
                fpr
                and ident.gpg is not None
                and (ident.gpg.sign_by_default or ident.gpg.encrypt_by_default)
            )
            base_fields["Override Encryption Defaults"] = _bool_str(
                override_encryption_defaults
            )

        grp_changed = False
        for k, v in base_fields.items():
            if kc.set(grp, k, v):
                grp_changed = True
                changed = True

        if not preserve_existing_gpg:
            if fpr and ident.gpg is not None:
                gpg_fields = {
                    "PGP Signing Key": fpr,
                    "PGP Encryption Key": fpr,
                    "Pgp Auto Sign": _bool_str(ident.gpg.sign_by_default),
                    "Pgp Auto Encrypt": _bool_str(ident.gpg.encrypt_by_default),
                    "Preferred Crypto Message Format": "openpgp/mime",
                    "Autocrypt": _bool_str(ident.gpg.autocrypt),
                }
                for k, v in gpg_fields.items():
                    if kc.set(grp, k, v):
                        grp_changed = True
                        changed = True
            else:
                for k in (
                    "PGP Signing Key",
                    "PGP Encryption Key",
                    "Pgp Auto Sign",
                    "Pgp Auto Encrypt",
                    "Preferred Crypto Message Format",
                    "Autocrypt",
                ):
                    if kc.remove_key(grp, k):
                        grp_changed = True
                        changed = True

        if grp_changed:
            gpg_status = "preserved" if preserve_existing_gpg else ("bound" if fpr else "none")
            actions.append(
                f"emailidentities: upsert {grp} ({ident.id}, gpg={gpg_status})"
            )

    if changed and not dry_run:
        kc.save_atomic(ei_path)

    # Also update emaildefaults
    ed_path = config_dir / "emaildefaults"
    ed = KConfigFile.load(ed_path)
    ed_changed = False
    if ed.set("Defaults", "Profile", "Default"):
        ed_changed = True
    if ed.set("PROFILE_Default", "EmailAddress", cfg.default_identity_spec.email):
        ed_changed = True
    if ed.set("PROFILE_Default", "FullName", cfg.default_identity_spec.real_name):
        ed_changed = True
    if ed_changed:
        actions.append(f"emaildefaults: updated PROFILE_Default for {cfg.default_identity_id}")
        if not dry_run:
            ed.save_atomic(ed_path)

    return actions, slug_to_uoid


def reconcile_imap_resources(
    cfg: ProvisionConfig,
    state: dict[str, Any],
    akonadi: AkonadiProtocol,
    keychain: KeychainProtocol,
    dry_run: bool,
    prune: bool,
    wait_seconds: int,
    state_file: Path | None = None,
) -> tuple[list[str], dict[str, str]]:
    actions: list[str] = []
    live_resources = set(akonadi.list_imap_resources())
    live_settings_cache: dict[str, dict[str, Any]] = {}

    def get_settings(res_id: str) -> dict[str, Any]:
        if res_id not in live_settings_cache:
            live_settings_cache[res_id] = akonadi.get_imap_settings(res_id)
        return live_settings_cache[res_id]

    prev_managed = state.setdefault("managed", {})

    # Reserve live recorded resources for all current accounts before fallback endpoint matching
    reserved_by_account: dict[str, str] = {}
    claimed_resources: set[str] = set()
    for acc in cfg.accounts:
        prev_entry = prev_managed.get(acc.id, {})
        recorded_id = prev_entry.get("resource_id") if isinstance(prev_entry, dict) else None
        if (
            isinstance(recorded_id, str)
            and recorded_id in live_resources
            and recorded_id not in claimed_resources
        ):
            reserved_by_account[acc.id] = recorded_id
            claimed_resources.add(recorded_id)

    assigned: dict[str, str] = {}

    def persist_checkpoint(
        acc: AccountSpec,
        res_id: str,
        *,
        pending_save: bool | None = None,
        pending_restart: bool | None = None,
    ) -> None:
        if dry_run or state_file is None:
            return
        # Transfer ownership atomically: remove res_id from any former owner entry
        for other_slug, other_entry in prev_managed.items():
            if other_slug != acc.id and isinstance(other_entry, dict):
                if other_entry.get("resource_id") == res_id:
                    other_entry.pop("resource_id", None)
                    other_entry.pop("pending_save", None)
                    other_entry.pop("pending_restart", None)
        entry = prev_managed.get(acc.id)
        if not isinstance(entry, dict):
            entry = {}
            prev_managed[acc.id] = entry
        entry["resource_id"] = res_id
        entry["transport_id"] = acc.transport_id
        entry["identity_uoid"] = acc.identity.uoid
        if pending_save is True:
            entry["pending_save"] = True
        elif pending_save is False:
            entry.pop("pending_save", None)
        if pending_restart is True:
            entry["pending_restart"] = True
        elif pending_restart is False:
            entry.pop("pending_restart", None)
        StateStore.save(state_file, state)

    for acc in cfg.accounts:
        res_id: str | None = reserved_by_account.get(acc.id)
        prev_entry = prev_managed.get(acc.id, {})
        prior_pending_save = bool(
            isinstance(prev_entry, dict) and prev_entry.get("pending_save")
        )
        prior_pending_restart = bool(
            isinstance(prev_entry, dict) and prev_entry.get("pending_restart")
        )

        if res_id is None:
            # Fallback match by (imapServer, userName) to recover from missing state.json
            for candidate in sorted(live_resources - claimed_resources):
                cand_cfg = get_settings(candidate)
                if (
                    cand_cfg.get("imapServer") == acc.imap.host
                    and cand_cfg.get("userName") == acc.imap.username
                ):
                    res_id = candidate
                    actions.append(
                        f"akonadi: matched existing resource {res_id} for {acc.id}"
                    )
                    break

        created_new = False
        if res_id is None:
            if dry_run:
                res_id = f"<new-akonadi_imap_resource:{acc.id}>"
                actions.append(f"akonadi: would create IMAP resource for {acc.id}")
            else:
                def _on_created(new_id: str, _acc: AccountSpec = acc) -> None:
                    persist_checkpoint(
                        _acc, new_id, pending_save=True, pending_restart=True
                    )

                res_id = akonadi.create_imap_resource(
                    wait_seconds, on_created=_on_created
                )
                live_resources.add(res_id)
                created_new = True
                actions.append(f"akonadi: created IMAP resource {res_id} for {acc.id}")

        claimed_resources.add(res_id)
        assigned[acc.id] = res_id

        desired_settings: dict[str, Any] = {
            "name": acc.name,
            "imapServer": acc.imap.host,
            "imapPort": acc.imap.port,
            "userName": acc.imap.username,
            "safety": acc.imap.safety,
            "authentication": IMAP_AUTH_ENUM[acc.imap.auth],
            "intervalCheckEnabled": acc.imap.interval_check_minutes > 0,
            "intervalCheckTime": acc.imap.interval_check_minutes,
            "disconnectedModeEnabled": acc.imap.disconnected_mode,
            "useDefaultIdentity": False,
            "accountIdentity": acc.identity.uoid,
        }

        if dry_run:
            if res_id.startswith("<new-"):
                actions.append(
                    f"akonadi: would configure {res_id} ({acc.imap.host}:{acc.imap.port})"
                )
            else:
                current = get_settings(res_id)
                diffs = {k: v for k, v in desired_settings.items() if current.get(k) != v}
                if diffs or prior_pending_save:
                    actions.append(
                        f"akonadi: would update {res_id} fields={sorted(diffs.keys())}"
                    )
                if prior_pending_restart:
                    actions.append(f"akonadi: would retry pending restart on {res_id}")
            actions.append(f"keychain: ensure password for (imap, {res_id}rc) [redacted]")
            continue

        if not created_new and prior_pending_save:
            wait_fn = getattr(akonadi, "wait_for_resource_settings", None)
            if callable(wait_fn):
                wait_fn(res_id, wait_seconds)

        current = get_settings(res_id)
        diffs = {k: v for k, v in desired_settings.items() if current.get(k) != v}
        settings_changed = created_new or bool(diffs) or prior_pending_save
        if settings_changed:
            persist_checkpoint(acc, res_id, pending_save=True, pending_restart=True)
            akonadi.apply_imap_settings(res_id, desired_settings)
            live_settings_cache[res_id] = dict(desired_settings)
            persist_checkpoint(acc, res_id, pending_save=False, pending_restart=True)
            actions.append(
                f"akonadi: applied IMAP settings on {res_id} ({acc.imap.host}:{acc.imap.port})"
            )

        # Persist pending_restart BEFORE the keychain write can commit so an interruption
        # right after commit still triggers a restart on the next run.
        persist_checkpoint(acc, res_id, pending_restart=True)
        pw_changed = keychain.set_password("imap", f"{res_id}rc", acc.imap.password)
        if pw_changed:
            actions.append(f"keychain: updated password for (imap, {res_id}rc)")

        if settings_changed or pw_changed or prior_pending_restart:
            akonadi.restart_resource(res_id, wait_seconds)
            persist_checkpoint(acc, res_id, pending_save=False, pending_restart=False)
            actions.append(f"akonadi: restarted {res_id}")
        else:
            persist_checkpoint(acc, res_id, pending_restart=False)

    if prune:
        desired_slugs = {acc.id for acc in cfg.accounts}
        for old_slug, old_entry in sorted(prev_managed.items()):
            if old_slug in desired_slugs or not isinstance(old_entry, dict):
                continue
            old_res = old_entry.get("resource_id")
            if isinstance(old_res, str) and old_res in live_resources and old_res not in claimed_resources:
                if dry_run:
                    actions.append(f"akonadi: would prune resource {old_res} ({old_slug})")
                else:
                    akonadi.remove_resource(old_res)
                    actions.append(f"akonadi: pruned resource {old_res} ({old_slug})")

    return actions, assigned


@contextlib.contextmanager
def _provision_lock(state_file: Path, *, enabled: bool) -> Iterator[None]:
    if not enabled:
        yield
        return
    lock_path = state_file.with_suffix(".lock")
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(str(lock_path), os.O_CREAT | os.O_RDWR, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        yield
    finally:
        try:
            fcntl.flock(fd, fcntl.LOCK_UN)
        finally:
            os.close(fd)


def _config_digest(path: Path) -> str | None:
    try:
        return hashlib.sha256(path.read_bytes()).hexdigest()
    except OSError:
        return None


def _checkpoint_transport_ids(
    cfg: ProvisionConfig, state: dict[str, Any], state_file: Path, *, prune: bool
) -> None:
    """Persist applied transport IDs before identity writes can fail, preserving identity UOIDs."""
    prev_managed = state.setdefault("managed", {})
    retired_tids: set[int] = {
        t for t in state.get("retired_transport_ids", []) if isinstance(t, int)
    }
    desired_tids = {tid for _, _, tid, _ in _iter_managed_transports(cfg)}
    for acc in cfg.accounts:
        entry = prev_managed.get(acc.id)
        if not isinstance(entry, dict):
            entry = {}
            prev_managed[acc.id] = entry
        prev_aliases = entry.get("aliases") if isinstance(entry.get("aliases"), dict) else {}
        alias_map: dict[str, Any] = {}
        for prev_aid, prev_aentry in prev_aliases.items():
            if isinstance(prev_aentry, dict):
                copied = dict(prev_aentry)
                if prune:
                    copied.pop("transport_id", None)
                alias_map[prev_aid] = copied
        for alias in acc.aliases:
            prev_alias = prev_aliases.get(alias.id)
            if (
                not prune
                and alias.smtp is None
                and isinstance(prev_alias, dict)
                and isinstance(prev_alias.get("transport_id"), int)
            ):
                retired_tids.add(prev_alias["transport_id"])
            a_entry: dict[str, Any] = (
                dict(alias_map[alias.id]) if alias.id in alias_map else {}
            )
            if alias.smtp is not None:
                a_entry["transport_id"] = alias.transport_id
            else:
                a_entry.pop("transport_id", None)
            if a_entry:
                alias_map[alias.id] = a_entry
        entry["transport_id"] = acc.transport_id
        entry["aliases"] = alias_map
    if prune:
        state.pop("retired_transport_ids", None)
    else:
        retired_tids -= desired_tids
        if retired_tids:
            state["retired_transport_ids"] = sorted(retired_tids)
        else:
            state.pop("retired_transport_ids", None)
    StateStore.save(state_file, state)


def _checkpoint_local_ids(
    cfg: ProvisionConfig, state: dict[str, Any], state_file: Path, *, prune: bool
) -> None:
    """Persist applied transport/identity/alias IDs before IMAP reconciliation starts."""
    prev_managed = state.setdefault("managed", {})
    retired_tids: set[int] = {
        t for t in state.get("retired_transport_ids", []) if isinstance(t, int)
    }
    desired_tids = {tid for _, _, tid, _ in _iter_managed_transports(cfg)}
    for acc in cfg.accounts:
        entry = prev_managed.get(acc.id)
        if not isinstance(entry, dict):
            entry = {}
            prev_managed[acc.id] = entry
        prev_aliases = entry.get("aliases") if isinstance(entry.get("aliases"), dict) else {}
        alias_map: dict[str, Any] = {}
        if not prune:
            for prev_aid, prev_aentry in prev_aliases.items():
                if isinstance(prev_aentry, dict):
                    alias_map[prev_aid] = dict(prev_aentry)
        for alias in acc.aliases:
            prev_alias = prev_aliases.get(alias.id)
            if (
                not prune
                and alias.smtp is None
                and isinstance(prev_alias, dict)
                and isinstance(prev_alias.get("transport_id"), int)
            ):
                retired_tids.add(prev_alias["transport_id"])
            a_entry: dict[str, Any] = {"identity_uoid": alias.uoid}
            if alias.smtp is not None:
                a_entry["transport_id"] = alias.transport_id
            alias_map[alias.id] = a_entry
        entry["transport_id"] = acc.transport_id
        entry["identity_uoid"] = acc.identity.uoid
        entry["aliases"] = alias_map
    if prune:
        state.pop("retired_transport_ids", None)
    else:
        retired_tids -= desired_tids
        if retired_tids:
            state["retired_transport_ids"] = sorted(retired_tids)
        else:
            state.pop("retired_transport_ids", None)
    StateStore.save(state_file, state)


def provision(
    config_path: Path,
    config_dir: Path,
    state_file: Path,
    dry_run: bool = False,
    prune: bool = False,
    wait_seconds: int = 30,
    akonadi: AkonadiProtocol | None = None,
    keychain: KeychainProtocol | None = None,
    gpg_runner: Callable[[list[str]], str | None] | None = None,
) -> int:
    """Reconcile KMail/Akonadi/QtKeychain state from a declarative JSON config."""
    # Validate early so malformed config fails fast before readiness polling
    cfg = load_config(config_path)

    akonadi_client: AkonadiProtocol = akonadi if akonadi is not None else AkonadiClient()
    keychain_client: KeychainProtocol = keychain if keychain is not None else KeychainClient()

    akonadi_available = False
    if not dry_run:
        keychain_client.ensure_ready(wait_seconds)
        akonadi_client.ensure_ready(wait_seconds)
        akonadi_available = True
    else:
        # Never call ensure_ready() during --dry-run; only use a read-only probe
        is_ready_fn = getattr(akonadi_client, "is_ready", None)
        if callable(is_ready_fn):
            akonadi_available = bool(is_ready_fn(timeout=min(5, max(1, wait_seconds))))

    all_actions: list[str] = []
    with _provision_lock(state_file, enabled=not dry_run):
        max_passes = 1 if dry_run else 5
        for _pass_idx in range(max_passes):
            digest_before: str | None = None
            if not dry_run:
                # Reload and hash exact parsed bytes under the lock
                cfg, digest_before = _load_config_with_digest(config_path)
            state = StateStore.load(state_file)

            all_actions.extend(
                reconcile_mailtransports(
                    cfg, config_dir, state, keychain_client, dry_run=dry_run, prune=prune
                )
            )
            if not dry_run:
                _checkpoint_transport_ids(cfg, state, state_file, prune=prune)

            id_actions, _ = reconcile_emailidentities(
                cfg, config_dir, state, gpg_runner=gpg_runner, dry_run=dry_run, prune=prune
            )
            all_actions.extend(id_actions)

            if not dry_run:
                _checkpoint_local_ids(cfg, state, state_file, prune=prune)

            assigned_resources: dict[str, str] = {}
            if akonadi_available:
                imap_actions, assigned_resources = reconcile_imap_resources(
                    cfg,
                    state,
                    akonadi_client,
                    keychain_client,
                    dry_run=dry_run,
                    prune=prune,
                    wait_seconds=wait_seconds,
                    state_file=state_file,
                )
                all_actions.extend(imap_actions)
            else:
                all_actions.append(
                    "akonadi: Akonadi is not running; skipping live IMAP diff without starting it"
                )

            prev_managed = state.get("managed", {})
            retired_tids: set[int] = {
                t for t in state.get("retired_transport_ids", []) if isinstance(t, int)
            }
            desired_tids = {tid for _, _, tid, _ in _iter_managed_transports(cfg)}
            active_resource_ids = set(assigned_resources.values())

            new_managed: dict[str, Any] = {}
            for acc in cfg.accounts:
                alias_map: dict[str, Any] = {}
                prev_acc = prev_managed.get(acc.id, {})
                prev_aliases = (
                    prev_acc.get("aliases", {})
                    if isinstance(prev_acc, dict) and isinstance(prev_acc.get("aliases"), dict)
                    else {}
                )
                if not prune:
                    for prev_alias_id, prev_alias_entry in prev_aliases.items():
                        if isinstance(prev_alias_entry, dict):
                            alias_map[prev_alias_id] = dict(prev_alias_entry)
                for alias in acc.aliases:
                    prev_alias = prev_aliases.get(alias.id)
                    if (
                        not prune
                        and alias.smtp is None
                        and isinstance(prev_alias, dict)
                        and isinstance(prev_alias.get("transport_id"), int)
                    ):
                        retired_tids.add(prev_alias["transport_id"])
                    alias_entry: dict[str, Any] = {"identity_uoid": alias.uoid}
                    if alias.smtp is not None:
                        alias_entry["transport_id"] = alias.transport_id
                    alias_map[alias.id] = alias_entry
                if acc.id in assigned_resources:
                    new_managed[acc.id] = {
                        "resource_id": assigned_resources[acc.id],
                        "transport_id": acc.transport_id,
                        "identity_uoid": acc.identity.uoid,
                        "aliases": alias_map,
                    }

            if not prune:
                for prev_slug, prev_entry in prev_managed.items():
                    if prev_slug not in new_managed and isinstance(prev_entry, dict):
                        copied = dict(prev_entry)
                        if copied.get("resource_id") in active_resource_ids:
                            copied.pop("resource_id", None)
                            copied.pop("pending_save", None)
                            copied.pop("pending_restart", None)
                        new_managed[prev_slug] = copied
                retired_tids -= desired_tids
            else:
                retired_tids.clear()

            if not dry_run:
                state_out: dict[str, Any] = {"version": 1, "managed": new_managed}
                if retired_tids:
                    state_out["retired_transport_ids"] = sorted(retired_tids)
                StateStore.save(state_file, state_out)
                digest_after = _config_digest(config_path)
                if digest_after is None or digest_after == digest_before:
                    break
            else:
                break
        else:
            if not dry_run:
                raise ProvisionError(
                    f"config file {config_path} changed during the final pass ({max_passes} reconciliation passes exhausted)"
                )

    if all_actions:
        prefix = "[dry-run] " if dry_run else ""
        for act in all_actions:
            LOG.info("%s%s", prefix, act)
            print(f"{prefix}{act}")
    else:
        LOG.info("KMail configuration already up to date")

    return EXIT_OK


def _default_config_dir() -> Path:
    xdg = os.environ.get("XDG_CONFIG_HOME")
    if xdg:
        return Path(xdg)
    return Path.home() / ".config"


def _default_state_file() -> Path:
    xdg = os.environ.get("XDG_DATA_HOME")
    base = Path(xdg) if xdg else Path.home() / ".local" / "share"
    return base / "kmail-provision" / "state.json"


def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="kmail-provision",
        description="Idempotently provision KMail/Akonadi/QtKeychain accounts from JSON.",
    )
    parser.add_argument(
        "--config",
        required=True,
        type=Path,
        help="Path to decrypted KMail JSON configuration (e.g. /run/agenix/joel-kmail.json)",
    )
    parser.add_argument(
        "--config-dir",
        type=Path,
        default=None,
        help="KDE config directory (default: $XDG_CONFIG_HOME or ~/.config)",
    )
    parser.add_argument(
        "--state-file",
        type=Path,
        default=None,
        help="Managed ID state manifest path (default: ~/.local/share/kmail-provision/state.json)",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Print planned operations with secrets redacted without making changes",
    )
    parser.add_argument(
        "--prune",
        action="store_true",
        help="Remove previously managed accounts no longer present in config",
    )
    parser.add_argument(
        "--wait-seconds",
        type=int,
        default=30,
        help="Seconds to wait for Akonadi and Secret Service/KWallet readiness (default: 30)",
    )
    parser.add_argument(
        "--verbose",
        action="store_true",
        help="Enable verbose debug logging",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_arg_parser()
    args = parser.parse_args(argv)

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(levelname)s: %(message)s",
    )

    config_dir = args.config_dir or _default_config_dir()
    state_file = args.state_file or _default_state_file()

    try:
        return provision(
            config_path=args.config,
            config_dir=config_dir,
            state_file=state_file,
            dry_run=args.dry_run,
            prune=args.prune,
            wait_seconds=args.wait_seconds,
        )
    except ConfigError as exc:
        print(f"kmail-provision config error: {exc}", file=sys.stderr)
        return EXIT_CONFIG_ERROR
    except SessionNotReadyError as exc:
        print(f"kmail-provision session not ready: {exc}", file=sys.stderr)
        return EXIT_SESSION_NOT_READY
    except ProvisionError as exc:
        print(f"kmail-provision error: {exc}", file=sys.stderr)
        return EXIT_PROVISION_ERROR


if __name__ == "__main__":
    raise SystemExit(main())
