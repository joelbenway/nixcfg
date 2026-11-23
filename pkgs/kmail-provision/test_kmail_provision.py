# Copyright (c) Joel Benway
# SPDX-License-Identifier: MIT
"""Unit tests for kmail-provision."""

from __future__ import annotations

import json
import logging
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent))

import kmail_provision as kp


def _write_json(tmp_path: Path, data: dict, name: str = "kmail.json") -> Path:
    p = tmp_path / name
    p.write_text(json.dumps(data), encoding="utf-8")
    return p


def test_gmail_preset_defaults_and_password_normalization(tmp_path: Path) -> None:
    cfg_path = _write_json(
        tmp_path,
        {
            "version": 1,
            "accounts": [
                {
                    "id": "personal",
                    "name": "Personal Gmail",
                    "provider": "gmail",
                    "email": "alice@example.com",
                    "realName": "Alice Example",
                    "password": "abcd efgh ijkl mnop",
                }
            ],
        },
    )

    cfg = kp.load_config(cfg_path)
    assert len(cfg.accounts) == 1
    acc = cfg.accounts[0]

    assert acc.id == "personal"
    assert acc.provider == "gmail"
    assert acc.imap.host == "imap.gmail.com"
    assert acc.imap.port == 993
    assert acc.imap.username == "alice@example.com"
    assert acc.imap.safety == "SSL"
    assert acc.imap.auth == "PLAIN"
    assert acc.imap.interval_check_minutes == 5
    assert acc.imap.disconnected_mode is True
    assert acc.imap.password == "abcdefghijklmnop"

    assert acc.smtp.host == "smtp.gmail.com"
    assert acc.smtp.port == 465
    assert acc.smtp.username == "alice@example.com"
    assert acc.smtp.encryption == "SSL"
    assert acc.smtp.auth == "PLAIN"
    assert acc.smtp.password == "abcdefghijklmnop"

    assert acc.identity.disable_fcc is True
    assert acc.identity.transport_id == acc.transport_id
    assert cfg.default_transport_id == acc.transport_id
    assert cfg.default_identity_uoid == acc.identity.uoid
    assert acc.identity.gpg == kp.GpgConfig(key="auto")


def test_custom_provider_preserves_password_spaces_and_requires_hosts(
    tmp_path: Path,
) -> None:
    cfg_path = _write_json(
        tmp_path,
        {
            "version": 1,
            "accounts": [
                {
                    "id": "work",
                    "name": "Work Mail",
                    "provider": "custom",
                    "email": "bob@work.example",
                    "realName": "Bob Work",
                    "password": "my secret pass with spaces",
                    "imap": {"host": "imap.work.example"},
                    "smtp": {"host": "smtp.work.example", "port": 587, "encryption": "TLS"},
                }
            ],
        },
    )

    cfg = kp.load_config(cfg_path)
    acc = cfg.accounts[0]
    assert acc.imap.host == "imap.work.example"
    assert acc.imap.port == 993
    assert acc.imap.password == "my secret pass with spaces"
    assert acc.smtp.host == "smtp.work.example"
    assert acc.smtp.port == 587
    assert acc.smtp.encryption == "TLS"
    assert acc.smtp.password == "my secret pass with spaces"
    assert acc.identity.disable_fcc is False

    missing_imap = _write_json(
        tmp_path,
        {
            "version": 1,
            "accounts": [
                {
                    "id": "bad1",
                    "name": "Bad",
                    "provider": "custom",
                    "email": "bob@work.example",
                    "realName": "Bob",
                    "password": "secret",
                    "smtp": {"host": "smtp.work.example"},
                }
            ],
        },
        name="missing_imap.json",
    )
    with pytest.raises(kp.ConfigError, match="imap.host"):
        kp.load_config(missing_imap)

    missing_smtp = _write_json(
        tmp_path,
        {
            "version": 1,
            "accounts": [
                {
                    "id": "bad2",
                    "name": "Bad",
                    "provider": "custom",
                    "email": "bob@work.example",
                    "realName": "Bob",
                    "password": "secret",
                    "imap": {"host": "imap.work.example"},
                }
            ],
        },
        name="missing_smtp.json",
    )
    with pytest.raises(kp.ConfigError, match="smtp.host"):
        kp.load_config(missing_smtp)


def test_aliases_inherit_parent_transport_and_default_identity_can_target_alias(
    tmp_path: Path,
) -> None:
    cfg_path = _write_json(
        tmp_path,
        {
            "version": 1,
            "defaultAccount": "main",
            "defaultIdentity": "domain",
            "accounts": [
                {
                    "id": "main",
                    "name": "Main Gmail",
                    "provider": "gmail",
                    "email": "alice@gmail.example",
                    "realName": "Alice Example",
                    "password": "aaaa bbbb cccc dddd",
                    "aliases": [
                        {
                            "id": "domain",
                            "name": "Alice (Custom Domain)",
                            "email": "alice@custom.example",
                            "realName": "Alice Example",
                        },
                        {
                            "id": "alt",
                            "name": "Alt Identity",
                            "email": "alt@duck.example",
                            "realName": "Alt Name",
                            "disableFcc": False,
                            "smtp": {
                                "host": "smtp.alt.example",
                                "port": 587,
                                "encryption": "TLS",
                                "username": "alt@duck.example",
                                "password": "alt secret",
                            },
                        },
                    ],
                }
            ],
        },
    )

    cfg = kp.load_config(cfg_path)
    main = cfg.accounts[0]
    assert len(main.aliases) == 2
    domain, alt = main.aliases

    # Inherited transport and disableFcc
    assert domain.transport_id == main.transport_id
    assert domain.smtp is None
    assert domain.disable_fcc is True

    # Custom alias SMTP transport
    assert alt.transport_id == kp.stable_transport_id("alt")
    assert alt.transport_id != main.transport_id
    assert alt.smtp is not None
    assert alt.smtp.host == "smtp.alt.example"
    assert alt.smtp.port == 587
    assert alt.smtp.encryption == "TLS"
    assert alt.smtp.password == "alt secret"
    assert alt.disable_fcc is False

    # Distinct deterministic UOIDs and defaultIdentity targeting alias
    uoids = {main.identity.uoid, domain.uoid, alt.uoid}
    assert len(uoids) == 3
    assert cfg.default_transport_id == main.transport_id
    assert cfg.default_identity_uoid == domain.uoid
    assert cfg.default_identity_spec.email == "alice@custom.example"


def test_validation_rejects_bad_version_duplicate_ids_and_unknown_defaults(
    tmp_path: Path,
) -> None:
    base_account = {
        "id": "main",
        "name": "Main",
        "provider": "gmail",
        "email": "alice@example.com",
        "realName": "Alice",
        "password": "abcd efgh ijkl mnop",
    }

    cases = [
        ({"version": 2, "accounts": [base_account]}, "version"),
        ({"version": 1, "accounts": []}, "accounts"),
        (
            {
                "version": 1,
                "accounts": [
                    {
                        **base_account,
                        "aliases": [
                            {
                                "id": "main",
                                "name": "Dup",
                                "email": "dup@example.com",
                                "realName": "Dup",
                            }
                        ],
                    }
                ],
            },
            "duplicate",
        ),
        (
            {
                "version": 1,
                "defaultAccount": "nonexistent",
                "accounts": [base_account],
            },
            "defaultAccount",
        ),
        (
            {
                "version": 1,
                "defaultIdentity": "nonexistent",
                "accounts": [base_account],
            },
            "defaultIdentity",
        ),
        (
            {
                "version": 1,
                "accounts": [{**base_account, "imap": {"safety": "BOGUS"}}],
            },
            "safety",
        ),
        (
            {
                "version": 1,
                "accounts": [{**base_account, "imap": {"auth": "BOGUS"}}],
            },
            "auth",
        ),
        (
            {
                "version": 1,
                "accounts": [{**base_account, "smtp": {"encryption": "BOGUS"}}],
            },
            "encryption",
        ),
    ]

    for idx, (payload, pattern) in enumerate(cases):
        p = _write_json(tmp_path, payload, name=f"bad_{idx}.json")
        with pytest.raises(kp.ConfigError, match=pattern):
            kp.load_config(p)


def test_stable_ids_are_deterministic_and_in_valid_ranges() -> None:
    tid1 = kp.stable_transport_id("personal")
    tid2 = kp.stable_transport_id("personal")
    assert tid1 == tid2
    assert 100_000 <= tid1 <= 999_999_998

    uoid1 = kp.stable_identity_uoid("personal")
    uoid2 = kp.stable_identity_uoid("personal")
    assert uoid1 == uoid2
    assert 100_000_000 <= uoid1 <= 2_099_999_999

    assert kp.stable_transport_id("a") != kp.stable_transport_id("b")
    assert kp.stable_identity_uoid("a") != kp.stable_identity_uoid("b")


def test_gpg_auto_match_unique_ambiguous_missing_and_revoked_expired(
    caplog: pytest.LogCaptureFixture,
) -> None:
    fpr_valid = "1111111111111111111111111111111111111111"
    fpr_dup1 = "2222222222222222222222222222222222222222"
    fpr_dup2 = "3333333333333333333333333333333333333333"
    fpr_revoked = "4444444444444444444444444444444444444444"
    fpr_expired = "5555555555555555555555555555555555555555"
    fpr_sub = "9999999999999999999999999999999999999999"

    gpg_colons = "\n".join(
        [
            "sec:u:255:22:KEY1:1700000000:::u:::scESC:::+:::23::0:",
            f"fpr:::::::::{fpr_valid}:",
            "uid:u::::1700000000::HASH1::Alice Example <Alice@Example.COM>::::::::::0:",
            "ssb:u:255:18:SUB1:1700000000::::::e:::+:::23:",
            f"fpr:::::::::{fpr_sub}:",
            "sec:u:255:22:KEY2:1700000000:::u:::scESC:::+:::23::0:",
            f"fpr:::::::::{fpr_dup1}:",
            "uid:u::::1700000000::HASH2::Dup One <dup@example.com>::::::::::0:",
            "sec:u:255:22:KEY3:1700000000:::u:::scESC:::+:::23::0:",
            f"fpr:::::::::{fpr_dup2}:",
            "uid:u::::1700000000::HASH3::Dup Two <dup@example.com>::::::::::0:",
            "sec:r:255:22:KEY4:1700000000:::r:::scESC:::+:::23::0:",
            f"fpr:::::::::{fpr_revoked}:",
            "uid:r::::1700000000::HASH4::Old <old@example.com>::::::::::0:",
            "sec:e:255:22:KEY5:1700000000:::e:::scESC:::+:::23::0:",
            f"fpr:::::::::{fpr_expired}:",
            "uid:e::::1700000000::HASH5::Old <old@example.com>::::::::::0:",
        ]
    )

    calls: list[list[str]] = []

    def fake_gpg(args: list[str]) -> str:
        calls.append(args)
        return gpg_colons

    # Unique case-insensitive match returns primary key fingerprint (not subkey)
    assert (
        kp.resolve_gpg_fingerprint(
            "alice@example.com", kp.GpgConfig(key="auto"), gpg_runner=fake_gpg
        )
        == fpr_valid
    )

    # Ambiguous match (>1) returns None and logs warning
    with caplog.at_level(logging.WARNING):
        assert (
            kp.resolve_gpg_fingerprint(
                "dup@example.com", kp.GpgConfig(key="auto"), gpg_runner=fake_gpg
            )
            is None
        )
    assert any("multiple" in rec.message.lower() for rec in caplog.records)

    # Revoked & expired keys are ignored
    assert (
        kp.resolve_gpg_fingerprint(
            "old@example.com", kp.GpgConfig(key="auto"), gpg_runner=fake_gpg
        )
        is None
    )

    # Missing match returns None
    assert (
        kp.resolve_gpg_fingerprint(
            "nobody@example.com", kp.GpgConfig(key="auto"), gpg_runner=fake_gpg
        )
        is None
    )

    # Explicit fingerprint returned directly without calling gpg
    calls.clear()
    explicit = "aabbccddeeff00112233445566778899aabbccdd"
    assert (
        kp.resolve_gpg_fingerprint(
            "alice@example.com", kp.GpgConfig(key=explicit), gpg_runner=fake_gpg
        )
        == explicit.upper()
    )
    assert calls == []

    # Disabled / None returns None without calling gpg
    assert (
        kp.resolve_gpg_fingerprint("alice@example.com", None, gpg_runner=fake_gpg)
        is None
    )
    assert (
        kp.resolve_gpg_fingerprint(
            "alice@example.com", kp.GpgConfig(enable=False), gpg_runner=fake_gpg
        )
        is None
    )
    assert calls == []
