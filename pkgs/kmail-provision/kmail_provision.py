#!/usr/bin/env python3
# Copyright (c) Joel Benway
# SPDX-License-Identifier: MIT
"""Idempotent declarative KMail provisioner for KDE Plasma 6 / Akonadi / QtKeychain."""

from __future__ import annotations

import hashlib
import json
import logging
import re
import subprocess
from collections.abc import Callable
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

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

VALID_IMAP_SAFETY = frozenset({"SSL", "STARTTLS", "None"})
VALID_SMTP_ENCRYPTION = frozenset({"SSL", "TLS", "None"})
VALID_SMTP_AUTH = frozenset(IMAP_AUTH_ENUM.keys())
VALID_PROVIDERS = frozenset({"gmail", "custom"})

_EMAIL_RE = re.compile(r"<([^<>]+@[^<>]+)>")
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


def _require_nonempty_str(obj: dict[str, Any], key: str, ctx: str) -> str:
    val = obj.get(key)
    if not isinstance(val, str) or not val.strip():
        raise ConfigError(f"{ctx}: missing or invalid string field '{key}'")
    return val.strip()


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

    port = raw_smtp.get("port", 465)
    if not isinstance(port, int) or isinstance(port, bool) or not (1 <= port <= 65535):
        raise ConfigError(f"{ctx}.smtp.port must be an integer 1..65535")

    username = raw_smtp.get("username", default_email)
    if not isinstance(username, str) or not username.strip():
        raise ConfigError(f"{ctx}.smtp.username must be a non-empty string")

    encryption = raw_smtp.get("encryption", "SSL")
    if encryption not in VALID_SMTP_ENCRYPTION:
        raise ConfigError(
            f"{ctx}.smtp.encryption '{encryption}' not in {sorted(VALID_SMTP_ENCRYPTION)}"
        )

    auth = raw_smtp.get("auth", "PLAIN")
    if auth not in VALID_SMTP_AUTH:
        raise ConfigError(
            f"{ctx}.smtp.auth '{auth}' not in {sorted(VALID_SMTP_AUTH)}"
        )

    raw_pw = raw_smtp.get("password", default_password)
    if not isinstance(raw_pw, str) or not raw_pw:
        raise ConfigError(f"{ctx}: missing password for SMTP")
    password = _normalize_password(raw_pw, provider)

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

    port = raw_imap.get("port", 993)
    if not isinstance(port, int) or isinstance(port, bool) or not (1 <= port <= 65535):
        raise ConfigError(f"{ctx}.imap.port must be an integer 1..65535")

    username = raw_imap.get("username", default_email)
    if not isinstance(username, str) or not username.strip():
        raise ConfigError(f"{ctx}.imap.username must be a non-empty string")

    safety = raw_imap.get("safety", "SSL")
    if safety not in VALID_IMAP_SAFETY:
        raise ConfigError(
            f"{ctx}.imap.safety '{safety}' not in {sorted(VALID_IMAP_SAFETY)}"
        )

    auth = raw_imap.get("auth", "PLAIN")
    if auth not in IMAP_AUTH_ENUM:
        raise ConfigError(
            f"{ctx}.imap.auth '{auth}' not in {sorted(IMAP_AUTH_ENUM)}"
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


def load_config(path: Path) -> ProvisionConfig:
    """Load, validate, and expand presets from a declarative KMail JSON file."""
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except OSError as exc:
        raise ConfigError(f"cannot read config file {path}: {exc}") from exc
    except json.JSONDecodeError as exc:
        raise ConfigError(f"invalid JSON in {path}: {exc}") from exc

    if not isinstance(raw, dict):
        raise ConfigError("config root must be a JSON object")

    if raw.get("version") != 1:
        raise ConfigError(f"unsupported config version: {raw.get('version')!r} (expected 1)")

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
        if provider not in VALID_PROVIDERS:
            raise ConfigError(f"{ctx}.provider '{provider}' not in {sorted(VALID_PROVIDERS)}")

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
    if default_account_id not in accounts_by_id:
        raise ConfigError(f"defaultAccount '{default_account_id}' does not match any account id")

    default_identity_id = raw.get("defaultIdentity", default_account_id)
    if default_identity_id not in identities_by_id:
        raise ConfigError(
            f"defaultIdentity '{default_identity_id}' does not match any account or alias id"
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


def _default_gpg_runner(args: list[str]) -> str:
    res = subprocess.run(
        args,
        capture_output=True,
        text=True,
        check=False,
        timeout=10,
    )
    if res.returncode != 0:
        LOG.warning("gpg command exited %d while resolving keys", res.returncode)
        return ""
    return res.stdout


def resolve_gpg_fingerprint(
    email: str,
    gpg_cfg: GpgConfig | None,
    gpg_runner: Callable[[list[str]], str] | None = None,
) -> str | None:
    """Resolve the GPG fingerprint to bind to an identity."""
    if gpg_cfg is None or not gpg_cfg.enable:
        return None
    if gpg_cfg.key != "auto":
        return gpg_cfg.key.upper()

    runner = gpg_runner or _default_gpg_runner
    output = runner(["gpg", "--list-secret-keys", "--with-colons"])
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
