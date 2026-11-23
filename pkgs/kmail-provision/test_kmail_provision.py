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


# ---------------------------------------------------------------------------
# Task 2 tests: KConfig merging, state store, reconciliation, dry-run, prune
# ---------------------------------------------------------------------------


class FakeAkonadiClient:
    def __init__(self, *, ready_error: Exception | None = None) -> None:
        self.ready_error = ready_error
        self.resources: dict[str, dict[str, object]] = {}
        self.counter = 0
        self.created: list[str] = []
        self.applied: list[tuple[str, dict[str, object]]] = []
        self.restarted: list[str] = []
        self.removed: list[str] = []

    def ensure_ready(self, wait_seconds: int) -> None:
        if self.ready_error is not None:
            raise self.ready_error

    def list_imap_resources(self) -> list[str]:
        return list(self.resources.keys())

    def get_imap_settings(self, resource_id: str) -> dict[str, object]:
        return dict(self.resources[resource_id])

    def create_imap_resource(self, wait_seconds: int, on_created=None) -> str:
        res_id = f"akonadi_imap_resource_{self.counter}"
        self.counter += 1
        self.resources[res_id] = {
            "name": "",
            "imapServer": "",
            "imapPort": 993,
            "userName": "",
            "safety": "SSL",
            "authentication": 7,
            "intervalCheckEnabled": False,
            "intervalCheckTime": 5,
            "disconnectedModeEnabled": False,
            "useDefaultIdentity": True,
            "accountIdentity": 0,
        }
        self.created.append(res_id)
        if on_created is not None:
            on_created(res_id)
        return res_id

    def apply_imap_settings(self, resource_id: str, settings: dict[str, object]) -> None:
        self.resources[resource_id].update(settings)
        self.applied.append((resource_id, dict(settings)))

    def restart_resource(self, resource_id: str) -> None:
        self.restarted.append(resource_id)

    def remove_resource(self, resource_id: str) -> None:
        self.resources.pop(resource_id, None)
        self.removed.append(resource_id)

    def reset_counters(self) -> None:
        self.created.clear()
        self.applied.clear()
        self.restarted.clear()
        self.removed.clear()


class FakeKeychainClient:
    def __init__(self, *, ready_error: Exception | None = None) -> None:
        self.ready_error = ready_error
        self.secrets: dict[tuple[str, str], str] = {}
        self.writes: list[tuple[str, str, str]] = []

    def ensure_ready(self, wait_seconds: int) -> None:
        if self.ready_error is not None:
            raise self.ready_error

    def set_password(self, service: str, key: str, password: str) -> bool:
        if self.secrets.get((service, key)) == password:
            return False
        self.secrets[(service, key)] = password
        self.writes.append((service, key, password))
        return True

    def reset_counters(self) -> None:
        self.writes.clear()


def _gmail_with_aliases_payload() -> dict:
    return {
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
                "password": "s3cr 3tpa sswd 9999",
                "aliases": [
                    {
                        "id": "domain",
                        "name": "Alice (Custom Domain)",
                        "email": "alice@custom.example",
                        "realName": "Alice Example",
                    },
                    {
                        "id": "duck",
                        "name": "Alice (Duck)",
                        "email": "alt@duck.example",
                        "realName": "Alt Name",
                    },
                ],
            }
        ],
    }


def _mock_gpg_for_three_identities() -> tuple[dict[str, str], object]:
    fprs = {
        "alice@gmail.example": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        "alice@custom.example": "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB",
        "alt@duck.example": "CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC",
    }
    colons = "\n".join(
        [
            "sec:u:255:22:K1:1700000000:::u:::scESC:::+:::23::0:",
            f"fpr:::::::::{fprs['alice@gmail.example']}:",
            "uid:u::::1700000000::H1::Alice Example <alice@gmail.example>::::::::::0:",
            "sec:u:255:22:K2:1700000000:::u:::scESC:::+:::23::0:",
            f"fpr:::::::::{fprs['alice@custom.example']}:",
            "uid:u::::1700000000::H2::Alice Example <alice@custom.example>::::::::::0:",
            "sec:u:255:22:K3:1700000000:::u:::scESC:::+:::23::0:",
            f"fpr:::::::::{fprs['alt@duck.example']}:",
            "uid:u::::1700000000::H3::Alt Name <alt@duck.example>::::::::::0:",
        ]
    )
    return fprs, lambda _args: colons


def test_kconfig_preserves_case_kde_syntax_and_unmanaged_groups(tmp_path: Path) -> None:
    rc = tmp_path / "sample.rc"
    original = (
        "# top comment\n"
        "[Unmanaged]\n"
        "Path[$e]=$HOME/.local/share/local-mail\n"
        "MixedCase Key=Keep Me\n"
        "\n"
        "[Identity #0]\n"
        "Email Address=old@example.com\n"
        "Disable Fcc=false\n"
    )
    rc.write_text(original, encoding="utf-8")

    kc = kp.KConfigFile.load(rc)
    assert kc.get("Unmanaged", "Path[$e]") == "$HOME/.local/share/local-mail"
    assert kc.set("Identity #0", "Email Address", "new@example.com") is True
    assert kc.set("Identity #0", "Email Address", "new@example.com") is False
    kc.save_atomic(rc)

    assert (rc.stat().st_mode & 0o777) == 0o600
    text = rc.read_text(encoding="utf-8")
    assert "# top comment\n" in text
    assert "Path[$e]=$HOME/.local/share/local-mail\n" in text
    assert "MixedCase Key=Keep Me\n" in text
    assert "Email Address=new@example.com\n" in text
    assert "Disable Fcc=false\n" in text


def test_provision_replaces_blank_firstrun_identity_and_preserves_unmanaged(
    tmp_path: Path,
) -> None:
    cfg_dir = tmp_path / "config"
    cfg_dir.mkdir()
    state_file = tmp_path / "state" / "state.json"

    # Seed francis-like blank first-run identity + a manual identity + an unmanaged transport
    (cfg_dir / "emailidentities").write_text(
        "[General]\n"
        "Default Identity=1301008340\n\n"
        "[Identity #0]\n"
        "Default Domain=francis\n"
        "Disable Fcc=false\n"
        "Identity=Joel Benway\n"
        "Name=Joel Benway\n"
        "uoid=1301008340\n\n"
        "[Identity #1]\n"
        "Email Address=manual@other.example\n"
        "Identity=Manual\n"
        "Name=Manual User\n"
        "uoid=424242\n",
        encoding="utf-8",
    )
    (cfg_dir / "mailtransports").write_text(
        "[General]\n"
        "default=999\n\n"
        "[Transport 999]\n"
        "id=999\n"
        "name=Manual SMTP\n"
        "host=smtp.manual.example\n",
        encoding="utf-8",
    )

    cfg_path = _write_json(tmp_path, _gmail_with_aliases_payload())
    fprs, gpg_runner = _mock_gpg_for_three_identities()
    akonadi = FakeAkonadiClient()
    keychain = FakeKeychainClient()

    rc = kp.provision(
        config_path=cfg_path,
        config_dir=cfg_dir,
        state_file=state_file,
        akonadi=akonadi,
        keychain=keychain,
        gpg_runner=gpg_runner,
    )
    assert rc == kp.EXIT_OK

    parsed = kp.load_config(cfg_path)
    main = parsed.accounts[0]
    domain, duck = main.aliases

    # Check emailidentities
    ei = kp.KConfigFile.load(cfg_dir / "emailidentities")
    assert ei.get("General", "Default Identity") == str(domain.uoid)
    id_groups = [g for g in ei.groups() if g.startswith("Identity #")]
    assert len(id_groups) == 4  # 1 manual + 3 managed; blank default replaced!
    by_email = {ei.get(g, "Email Address"): g for g in id_groups}
    assert "" not in by_email and None not in by_email
    assert "manual@other.example" in by_email

    for spec in (main.identity, domain, duck):
        grp = by_email[spec.email]
        assert ei.get(grp, "uoid") == str(spec.uoid)
        assert ei.get(grp, "Transport") == str(main.transport_id)
        assert ei.get(grp, "Disable Fcc") == "true"
        assert ei.get(grp, "PGP Signing Key") == fprs[spec.email]
        assert ei.get(grp, "PGP Encryption Key") == fprs[spec.email]
        assert ei.get(grp, "Preferred Crypto Message Format") == "openpgp/mime"

    # Check emaildefaults
    ed = kp.KConfigFile.load(cfg_dir / "emaildefaults")
    assert ed.get("PROFILE_Default", "EmailAddress") == "alice@custom.example"
    assert ed.get("PROFILE_Default", "FullName") == "Alice Example"

    # Check mailtransports
    mt = kp.KConfigFile.load(cfg_dir / "mailtransports")
    assert mt.get("General", "default") == str(main.transport_id)
    assert mt.get("Transport 999", "host") == "smtp.manual.example"
    tgrp = f"Transport {main.transport_id}"
    assert mt.get(tgrp, "host") == "smtp.gmail.com"
    assert mt.get(tgrp, "port") == "465"
    assert mt.get(tgrp, "encryption") == "SSL"
    assert mt.get(tgrp, "authtype") == "PLAIN"
    assert mt.get(tgrp, "auth") == "true"
    assert mt.get(tgrp, "storepass") == "true"

    # Check Akonadi IMAP resource
    assert len(akonadi.created) == 1
    res_id = akonadi.created[0]
    res_settings = akonadi.resources[res_id]
    assert res_settings["imapServer"] == "imap.gmail.com"
    assert res_settings["imapPort"] == 993
    assert res_settings["userName"] == "alice@gmail.example"
    assert res_settings["safety"] == "SSL"
    assert res_settings["authentication"] == 1  # PLAIN
    assert res_settings["useDefaultIdentity"] is False
    assert res_settings["accountIdentity"] == main.identity.uoid
    assert akonadi.restarted == [res_id]

    # Check QtKeychain targets
    assert keychain.secrets[("mailtransports", str(main.transport_id))] == "s3cr3tpassw d9999".replace(" ", "")
    assert keychain.secrets[("imap", f"{res_id}rc")] == "s3cr3tpassw d9999".replace(" ", "")


def test_provision_second_run_is_strict_noop(tmp_path: Path) -> None:
    cfg_dir = tmp_path / "config"
    cfg_dir.mkdir()
    state_file = tmp_path / "state.json"
    cfg_path = _write_json(tmp_path, _gmail_with_aliases_payload())
    _, gpg_runner = _mock_gpg_for_three_identities()
    akonadi = FakeAkonadiClient()
    keychain = FakeKeychainClient()

    assert (
        kp.provision(
            config_path=cfg_path,
            config_dir=cfg_dir,
            state_file=state_file,
            akonadi=akonadi,
            keychain=keychain,
            gpg_runner=gpg_runner,
        )
        == kp.EXIT_OK
    )

    akonadi.reset_counters()
    keychain.reset_counters()

    assert (
        kp.provision(
            config_path=cfg_path,
            config_dir=cfg_dir,
            state_file=state_file,
            akonadi=akonadi,
            keychain=keychain,
            gpg_runner=gpg_runner,
        )
        == kp.EXIT_OK
    )

    assert akonadi.created == []
    assert akonadi.applied == []
    assert akonadi.restarted == []
    assert keychain.writes == []


def test_provision_recovers_when_state_file_missing_or_resource_deleted(
    tmp_path: Path,
) -> None:
    cfg_dir = tmp_path / "config"
    cfg_dir.mkdir()
    state_file = tmp_path / "state.json"
    cfg_path = _write_json(tmp_path, _gmail_with_aliases_payload())
    _, gpg_runner = _mock_gpg_for_three_identities()
    akonadi = FakeAkonadiClient()
    keychain = FakeKeychainClient()

    kp.provision(
        config_path=cfg_path,
        config_dir=cfg_dir,
        state_file=state_file,
        akonadi=akonadi,
        keychain=keychain,
        gpg_runner=gpg_runner,
    )
    original_res_id = akonadi.created[0]

    # Subcase A: state.json deleted -> fallback match by (imapServer, userName)
    state_file.unlink()
    akonadi.reset_counters()
    kp.provision(
        config_path=cfg_path,
        config_dir=cfg_dir,
        state_file=state_file,
        akonadi=akonadi,
        keychain=keychain,
        gpg_runner=gpg_runner,
    )
    assert akonadi.created == []
    state = json.loads(state_file.read_text(encoding="utf-8"))
    assert state["managed"]["main"]["resource_id"] == original_res_id

    # Subcase B: IMAP resource manually deleted in KMail -> recreated cleanly
    akonadi.resources.pop(original_res_id)
    akonadi.reset_counters()
    kp.provision(
        config_path=cfg_path,
        config_dir=cfg_dir,
        state_file=state_file,
        akonadi=akonadi,
        keychain=keychain,
        gpg_runner=gpg_runner,
    )
    assert len(akonadi.created) == 1
    assert akonadi.created[0] != original_res_id
    state2 = json.loads(state_file.read_text(encoding="utf-8"))
    assert state2["managed"]["main"]["resource_id"] == akonadi.created[0]


def test_dry_run_makes_no_mutations_and_redacts_passwords(
    tmp_path: Path, capsys: pytest.CaptureFixture[str], caplog: pytest.LogCaptureFixture
) -> None:
    cfg_dir = tmp_path / "config"
    cfg_dir.mkdir()
    state_file = tmp_path / "state.json"
    cfg_path = _write_json(tmp_path, _gmail_with_aliases_payload())
    _, gpg_runner = _mock_gpg_for_three_identities()
    akonadi = FakeAkonadiClient()
    keychain = FakeKeychainClient()

    with caplog.at_level(logging.DEBUG):
        rc = kp.provision(
            config_path=cfg_path,
            config_dir=cfg_dir,
            state_file=state_file,
            dry_run=True,
            akonadi=akonadi,
            keychain=keychain,
            gpg_runner=gpg_runner,
        )

    assert rc == kp.EXIT_OK
    assert list(cfg_dir.iterdir()) == []
    assert not state_file.exists()
    assert akonadi.created == []
    assert akonadi.applied == []
    assert keychain.writes == []

    captured = capsys.readouterr()
    combined = captured.out + captured.err + "\n".join(r.getMessage() for r in caplog.records)
    assert "s3cr" not in combined
    assert "3tpa" not in combined
    assert "s3cr3tpassw" not in combined


def test_prune_removes_only_managed_entries(tmp_path: Path) -> None:
    cfg_dir = tmp_path / "config"
    cfg_dir.mkdir()
    state_file = tmp_path / "state.json"

    # Seed unmanaged transport, identity, and IMAP resource
    (cfg_dir / "mailtransports").write_text(
        "[General]\ndefault=777\n\n[Transport 777]\nid=777\nhost=smtp.unmanaged.example\n",
        encoding="utf-8",
    )
    (cfg_dir / "emailidentities").write_text(
        "[General]\nDefault Identity=777777\n\n"
        "[Identity #0]\nEmail Address=keep@unmanaged.example\nIdentity=Keep\nuoid=777777\n",
        encoding="utf-8",
    )
    akonadi = FakeAkonadiClient()
    akonadi.resources["akonadi_imap_resource_99"] = {
        "name": "Unmanaged IMAP",
        "imapServer": "imap.unmanaged.example",
        "userName": "keep@unmanaged.example",
    }
    keychain = FakeKeychainClient()

    two_accounts = _write_json(
        tmp_path,
        {
            "version": 1,
            "accounts": [
                {
                    "id": "one",
                    "name": "One",
                    "provider": "gmail",
                    "email": "one@example.com",
                    "realName": "One",
                    "password": "aaaa bbbb cccc dddd",
                },
                {
                    "id": "two",
                    "name": "Two",
                    "provider": "gmail",
                    "email": "two@example.com",
                    "realName": "Two",
                    "password": "eeee ffff gggg hhhh",
                },
            ],
        },
        name="two.json",
    )
    kp.provision(
        config_path=two_accounts,
        config_dir=cfg_dir,
        state_file=state_file,
        akonadi=akonadi,
        keychain=keychain,
        gpg_runner=lambda _a: "",
    )
    res_two = json.loads(state_file.read_text(encoding="utf-8"))["managed"]["two"]["resource_id"]

    one_account = _write_json(
        tmp_path,
        {
            "version": 1,
            "accounts": [
                {
                    "id": "one",
                    "name": "One",
                    "provider": "gmail",
                    "email": "one@example.com",
                    "realName": "One",
                    "password": "aaaa bbbb cccc dddd",
                }
            ],
        },
        name="one.json",
    )
    kp.provision(
        config_path=one_account,
        config_dir=cfg_dir,
        state_file=state_file,
        prune=True,
        akonadi=akonadi,
        keychain=keychain,
        gpg_runner=lambda _a: "",
    )

    assert res_two in akonadi.removed
    assert "akonadi_imap_resource_99" in akonadi.resources
    mt = kp.KConfigFile.load(cfg_dir / "mailtransports")
    assert f"Transport {kp.stable_transport_id('two')}" not in mt.groups()
    assert "Transport 777" in mt.groups()
    ei = kp.KConfigFile.load(cfg_dir / "emailidentities")
    uoids = {ei.get(g, "uoid") for g in ei.groups() if g.startswith("Identity #")}
    assert str(kp.stable_identity_uoid("two")) not in uoids
    assert "777777" in uoids
    assert str(kp.stable_identity_uoid("one")) in uoids


def test_session_not_ready_returns_exit_code_2_without_mutating_state(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    cfg_dir = tmp_path / "config"
    cfg_dir.mkdir()
    state_file = tmp_path / "state.json"
    cfg_path = _write_json(tmp_path, _gmail_with_aliases_payload())

    monkeypatch.setattr(
        kp,
        "KeychainClient",
        lambda: FakeKeychainClient(ready_error=kp.SessionNotReadyError("wallet locked")),
    )
    monkeypatch.setattr(kp, "AkonadiClient", lambda: FakeAkonadiClient())

    rc = kp.main(
        [
            "--config",
            str(cfg_path),
            "--config-dir",
            str(cfg_dir),
            "--state-file",
            str(state_file),
            "--wait-seconds",
            "1",
        ]
    )
    assert rc == kp.EXIT_SESSION_NOT_READY
    assert not state_file.exists()
    assert list(cfg_dir.iterdir()) == []
    captured = capsys.readouterr()
    assert "s3cr" not in (captured.out + captured.err)


def test_state_file_contains_no_passwords_and_has_0600_mode(tmp_path: Path) -> None:
    cfg_dir = tmp_path / "config"
    cfg_dir.mkdir()
    state_file = tmp_path / "state.json"
    cfg_path = _write_json(tmp_path, _gmail_with_aliases_payload())
    _, gpg_runner = _mock_gpg_for_three_identities()

    kp.provision(
        config_path=cfg_path,
        config_dir=cfg_dir,
        state_file=state_file,
        akonadi=FakeAkonadiClient(),
        keychain=FakeKeychainClient(),
        gpg_runner=gpg_runner,
    )

    assert (state_file.stat().st_mode & 0o777) == 0o600
    raw = state_file.read_text(encoding="utf-8")
    assert "s3cr" not in raw
    assert "3tpa" not in raw
    assert "alice@gmail.example" not in raw


# ---------------------------------------------------------------------------
# Regression tests for whole-branch review findings
# ---------------------------------------------------------------------------


def test_keychain_client_locked_wallet_polls_and_times_out_with_session_not_ready(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.delenv("KDE_FULL_SESSION", raising=False)
    monkeypatch.delenv("XDG_CURRENT_DESKTOP", raising=False)
    monkeypatch.delenv("QTKEYCHAIN_BACKEND", raising=False)
    calls: list[list[str]] = []

    def fake_run(args: list[str], **_kwargs: object) -> object:
        calls.append(args)

        class _Res:
            def __init__(self, rc: int, out: str = "", err: str = "") -> None:
                self.returncode = rc
                self.stdout = out
                self.stderr = err

        # Both D-Bus services exist, but wallet is LOCKED!
        if "Locked" in args:
            return _Res(0, "true\n")
        if any("localWallet" in a for a in args):
            return _Res(0, "kdewallet\n")
        if any("isOpen" in a for a in args):
            return _Res(0, "false\n")
        return _Res(0, "/\n")

    monkeypatch.setattr(kp.subprocess, "run", fake_run)
    monkeypatch.setattr(kp.time, "sleep", lambda _s: None)
    now = [0.0]

    def fake_monotonic() -> float:
        now[0] += 0.6
        return now[0]

    monkeypatch.setattr(kp.time, "monotonic", fake_monotonic)

    client = kp.KeychainClient()
    with pytest.raises(kp.SessionNotReadyError):
        client.ensure_ready(wait_seconds=1)
    assert any("Locked" in c for c in calls)


def test_keychain_client_unlocked_and_stdin_password_and_timeout(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.delenv("KDE_FULL_SESSION", raising=False)
    monkeypatch.delenv("XDG_CURRENT_DESKTOP", raising=False)
    monkeypatch.delenv("QTKEYCHAIN_BACKEND", raising=False)
    captured_inputs: list[tuple[list[str], str | None]] = []

    def fake_run(args: list[str], **kwargs: object) -> object:
        captured_inputs.append((args, kwargs.get("input")))  # type: ignore[arg-type]

        class _Res:
            def __init__(self, rc: int, out: str = "", err: str = "") -> None:
                self.returncode = rc
                self.stdout = out
                self.stderr = err

        if "Locked" in args:
            return _Res(0, "false\n")
        if args[0] == "kmail-keychain-set":
            if args[2] == "already":
                return _Res(0, "unchanged\n")
            if args[2] == "timeout":
                raise kp.subprocess.TimeoutExpired(cmd=args, timeout=15)
            return _Res(0, "updated\n")
        return _Res(1, "", "unexpected")

    monkeypatch.setattr(kp.subprocess, "run", fake_run)
    client = kp.KeychainClient()
    client.ensure_ready(wait_seconds=1)

    assert client.set_password("mailtransports", "123", "my-secret-pw") is True
    assert client.set_password("mailtransports", "already", "my-secret-pw") is False

    # Password passed strictly via stdin, never in argv
    helper_call = [c for c in captured_inputs if c[0][0] == "kmail-keychain-set"][0]
    assert "my-secret-pw" not in " ".join(helper_call[0])
    assert helper_call[1] == "my-secret-pw"

    # Timeout converts cleanly to SessionNotReadyError (never leaks password)
    with pytest.raises(kp.SessionNotReadyError) as exc_info:
        client.set_password("mailtransports", "timeout", "my-secret-pw")
    assert "my-secret-pw" not in str(exc_info.value)


def test_akonadi_client_qdbus_operations_and_timeout_handling(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    set_calls: list[list[str]] = []

    def fake_run(args: list[str], **_kwargs: object) -> object:
        class _Res:
            def __init__(self, rc: int, out: str = "", err: str = "") -> None:
                self.returncode = rc
                self.stdout = out
                self.stderr = err

        if args[0] == "qdbus":
            if args[-1].endswith(".agentInstances"):
                return _Res(0, "akonadi_imap_resource_0\nakonadi_maildir_resource_0\n")
            if args[-2].endswith(".agentInstanceType"):
                return _Res(
                    0,
                    "akonadi_imap_resource\n"
                    if args[-1] == "akonadi_imap_resource_0"
                    else "akonadi_maildir_resource\n",
                )
            if ".imapServer" in args[-1]:
                return _Res(0, "imap.gmail.com\n")
            if ".imapPort" in args[-1]:
                return _Res(0, "993\n")
            if ".userName" in args[-1]:
                return _Res(0, "alice@example.com\n")
            if ".safety" in args[-1]:
                return _Res(0, "SSL\n")
            if ".authentication" in args[-1]:
                return _Res(0, "1\n")
            if ".intervalCheckEnabled" in args[-1]:
                return _Res(0, "true\n")
            if ".intervalCheckTime" in args[-1]:
                return _Res(0, "5\n")
            if ".disconnectedModeEnabled" in args[-1]:
                return _Res(0, "true\n")
            if ".useDefaultIdentity" in args[-1]:
                return _Res(0, "false\n")
            if ".accountIdentity" in args[-1]:
                return _Res(0, "123456\n")
            if ".name" in args[-1]:
                return _Res(0, "Personal\n")
            set_calls.append(args)
            return _Res(0, "")
        return _Res(0, "")

    monkeypatch.setattr(kp.subprocess, "run", fake_run)
    client = kp.AkonadiClient()
    client.ensure_ready(wait_seconds=1)
    assert client.list_imap_resources() == ["akonadi_imap_resource_0"]
    settings = client.get_imap_settings("akonadi_imap_resource_0")
    assert settings["imapServer"] == "imap.gmail.com"
    assert settings["imapPort"] == 993
    assert settings["authentication"] == 1
    assert settings["intervalCheckEnabled"] is True

    client.apply_imap_settings(
        "akonadi_imap_resource_0",
        {"imapServer": "imap.gmail.com", "imapPort": 993, "useDefaultIdentity": False},
    )
    assert any(c[-1].endswith(".save") for c in set_calls)

    # Timeout during qdbus ensure_ready raises SessionNotReadyError cleanly
    def raise_timeout(args: list[str], **_kwargs: object) -> object:
        raise kp.subprocess.TimeoutExpired(cmd=args, timeout=10)

    monkeypatch.setattr(kp.subprocess, "run", raise_timeout)
    monkeypatch.setattr(kp.time, "sleep", lambda _s: None)
    now = [0.0]
    monkeypatch.setattr(
        kp.time, "monotonic", lambda: (now.__setitem__(0, now[0] + 1.0) or now[0])
    )
    with pytest.raises(kp.SessionNotReadyError):
        client.ensure_ready(wait_seconds=1)


def test_gpg_sign_or_encrypt_by_default_sets_override_encryption_defaults(
    tmp_path: Path,
) -> None:
    cfg_dir = tmp_path / "config"
    cfg_dir.mkdir()
    state_file = tmp_path / "state.json"

    payload = {
        "version": 1,
        "accounts": [
            {
                "id": "signed",
                "name": "Signed Gmail",
                "provider": "gmail",
                "email": "alice@gmail.example",
                "realName": "Alice Example",
                "password": "aaaa bbbb cccc dddd",
                "gpg": {
                    "key": "auto",
                    "signByDefault": True,
                    "encryptByDefault": False,
                },
                "aliases": [
                    {
                        "id": "encrypted",
                        "name": "Encrypted Alias",
                        "email": "alice@custom.example",
                        "realName": "Alice Example",
                        "gpg": {
                            "key": "auto",
                            "signByDefault": False,
                            "encryptByDefault": True,
                        },
                    },
                    {
                        "id": "default_crypto",
                        "name": "Default Crypto Alias",
                        "email": "alt@duck.example",
                        "realName": "Alt Name",
                        "gpg": {
                            "key": "auto",
                            "signByDefault": False,
                            "encryptByDefault": False,
                        },
                    },
                ],
            }
        ],
    }
    cfg_path = _write_json(tmp_path, payload)
    _, gpg_runner = _mock_gpg_for_three_identities()

    kp.provision(
        config_path=cfg_path,
        config_dir=cfg_dir,
        state_file=state_file,
        akonadi=FakeAkonadiClient(),
        keychain=FakeKeychainClient(),
        gpg_runner=gpg_runner,
    )

    ei = kp.KConfigFile.load(cfg_dir / "emailidentities")
    by_email = {
        ei.get(g, "Email Address"): g
        for g in ei.groups()
        if g.startswith("Identity #")
    }
    assert ei.get(by_email["alice@gmail.example"], "Override Encryption Defaults") == "true"
    assert ei.get(by_email["alice@gmail.example"], "Pgp Auto Sign") == "true"
    assert ei.get(by_email["alice@custom.example"], "Override Encryption Defaults") == "true"
    assert ei.get(by_email["alice@custom.example"], "Pgp Auto Encrypt") == "true"
    assert ei.get(by_email["alt@duck.example"], "Override Encryption Defaults") == "false"


def test_non_prune_run_preserves_removed_entries_in_state_for_later_prune(
    tmp_path: Path,
) -> None:
    cfg_dir = tmp_path / "config"
    cfg_dir.mkdir()
    state_file = tmp_path / "state.json"
    akonadi = FakeAkonadiClient()
    keychain = FakeKeychainClient()

    two_payload = {
        "version": 1,
        "accounts": [
            {
                "id": "one",
                "name": "One",
                "provider": "gmail",
                "email": "one@example.com",
                "realName": "One",
                "password": "aaaa bbbb cccc dddd",
                "aliases": [
                    {
                        "id": "alias_smtp",
                        "name": "Alias With SMTP",
                        "email": "alias@custom.example",
                        "realName": "Alias",
                        "smtp": {
                            "host": "smtp.custom.example",
                            "port": 465,
                            "username": "alias@custom.example",
                            "password": "alias-secret",
                        },
                    }
                ],
            },
            {
                "id": "two",
                "name": "Two",
                "provider": "gmail",
                "email": "two@example.com",
                "realName": "Two",
                "password": "eeee ffff gggg hhhh",
            },
        ],
    }
    p_two = _write_json(tmp_path, two_payload, name="two.json")
    kp.provision(
        config_path=p_two,
        config_dir=cfg_dir,
        state_file=state_file,
        akonadi=akonadi,
        keychain=keychain,
        gpg_runner=lambda _a: "",
    )
    res_two = json.loads(state_file.read_text(encoding="utf-8"))["managed"]["two"]["resource_id"]

    # Remove account 'two' and alias 'alias_smtp', run WITHOUT prune first (like PathChanged auto-run)
    one_payload = {
        "version": 1,
        "accounts": [
            {
                "id": "one",
                "name": "One",
                "provider": "gmail",
                "email": "one@example.com",
                "realName": "One",
                "password": "aaaa bbbb cccc dddd",
            }
        ],
    }
    p_one = _write_json(tmp_path, one_payload, name="one.json")
    kp.provision(
        config_path=p_one,
        config_dir=cfg_dir,
        state_file=state_file,
        prune=False,
        akonadi=akonadi,
        keychain=keychain,
        gpg_runner=lambda _a: "",
    )

    # State must still remember unpruned account 'two' and alias 'alias_smtp'
    mid_state = json.loads(state_file.read_text(encoding="utf-8"))
    assert "two" in mid_state["managed"]
    assert "alias_smtp" in mid_state["managed"]["one"]["aliases"]

    # Dry-run with --prune must NOT remove anything
    kp.provision(
        config_path=p_one,
        config_dir=cfg_dir,
        state_file=state_file,
        dry_run=True,
        prune=True,
        akonadi=akonadi,
        keychain=keychain,
        gpg_runner=lambda _a: "",
    )
    assert res_two in akonadi.resources

    # Subsequent real --prune run must now clean up both 'two' and 'alias_smtp' transport + identity
    kp.provision(
        config_path=p_one,
        config_dir=cfg_dir,
        state_file=state_file,
        prune=True,
        akonadi=akonadi,
        keychain=keychain,
        gpg_runner=lambda _a: "",
    )
    assert res_two not in akonadi.resources
    mt = kp.KConfigFile.load(cfg_dir / "mailtransports")
    assert f"Transport {kp.stable_transport_id('two')}" not in mt.groups()
    assert f"Transport {kp.stable_transport_id('alias_smtp')}" not in mt.groups()
    ei = kp.KConfigFile.load(cfg_dir / "emailidentities")
    uoids = {ei.get(g, "uoid") for g in ei.groups() if g.startswith("Identity #")}
    assert str(kp.stable_identity_uoid("two")) not in uoids
    assert str(kp.stable_identity_uoid("alias_smtp")) not in uoids
    final_state = json.loads(state_file.read_text(encoding="utf-8"))
    assert "two" not in final_state["managed"]
    assert "alias_smtp" not in final_state["managed"]["one"]["aliases"]


def test_unhashable_json_values_and_duplicate_accounts_raise_config_error(
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
        {"version": 1, "defaultAccount": ["main"], "accounts": [base_account]},
        {"version": 1, "defaultIdentity": {"id": "main"}, "accounts": [base_account]},
        {"version": 1, "accounts": [{**base_account, "provider": ["gmail"]}]},
        {"version": 1, "accounts": [{**base_account, "imap": {"safety": ["SSL"]}}]},
        {"version": 1, "accounts": [{**base_account, "imap": {"auth": {"x": 1}}}]},
        {"version": 1, "accounts": [{**base_account, "smtp": {"encryption": ["SSL"]}}]},
        {"version": 1, "accounts": [{**base_account, "smtp": {"auth": ["PLAIN"]}}]},
        # Duplicate id across two top-level accounts
        {"version": 1, "accounts": [base_account, dict(base_account)]},
        # defaultAccount targeting an alias id
        {
            "version": 1,
            "defaultAccount": "myalias",
            "accounts": [
                {
                    **base_account,
                    "aliases": [
                        {
                            "id": "myalias",
                            "name": "My Alias",
                            "email": "alias@example.com",
                            "realName": "Alias",
                        }
                    ],
                }
            ],
        },
    ]
    for idx, payload in enumerate(cases):
        p = _write_json(tmp_path, payload, name=f"unhashable_{idx}.json")
        with pytest.raises(kp.ConfigError):
            kp.load_config(p)


# ---------------------------------------------------------------------------
# Regression tests for PR #14 CodeRabbit review findings
# ---------------------------------------------------------------------------


def test_validation_errors_never_echo_raw_json_values_or_passwords(tmp_path: Path) -> None:
    secret_pw = "ULTRA_SECRET_APP_PW_9988"
    bad_payload = {
        "version": 1,
        "defaultAccount": {"id": "main", "password": secret_pw},
        "accounts": [
            {
                "id": "main",
                "name": "Main",
                "provider": "gmail",
                "email": "alice@example.com",
                "realName": "Alice",
                "password": secret_pw,
            }
        ],
    }
    p = _write_json(tmp_path, bad_payload, name="leak_check.json")
    with pytest.raises(kp.ConfigError) as exc_info:
        kp.load_config(p)
    assert secret_pw not in str(exc_info.value)

    # Reject APOP for IMAP (POP3-only)
    apop_payload = {
        "version": 1,
        "accounts": [
            {
                "id": "main",
                "name": "Main",
                "provider": "gmail",
                "email": "alice@example.com",
                "realName": "Alice",
                "password": secret_pw,
                "imap": {"auth": "APOP"},
            }
        ],
    }
    p_apop = _write_json(tmp_path, apop_payload, name="apop.json")
    with pytest.raises(kp.ConfigError, match="imap.auth"):
        kp.load_config(p_apop)

    # Reject newlines inside single-line identity fields (KConfig injection)
    nl_payload = {
        "version": 1,
        "accounts": [
            {
                "id": "main",
                "name": "Alice\nInjected=true",
                "provider": "gmail",
                "email": "alice@example.com",
                "realName": "Alice",
                "password": secret_pw,
            }
        ],
    }
    p_nl = _write_json(tmp_path, nl_payload, name="newline.json")
    with pytest.raises(kp.ConfigError, match="newline"):
        kp.load_config(p_nl)


def test_failed_gpg_listing_preserves_existing_pgp_binding(tmp_path: Path) -> None:
    cfg_dir = tmp_path / "config"
    cfg_dir.mkdir()
    state_file = tmp_path / "state.json"
    cfg_path = _write_json(tmp_path, _gmail_with_aliases_payload())
    fprs, gpg_runner = _mock_gpg_for_three_identities()
    akonadi = FakeAkonadiClient()
    keychain = FakeKeychainClient()

    kp.provision(
        config_path=cfg_path,
        config_dir=cfg_dir,
        state_file=state_file,
        akonadi=akonadi,
        keychain=keychain,
        gpg_runner=gpg_runner,
    )

    # Simulate transient gpg failure (returns None instead of str)
    kp.provision(
        config_path=cfg_path,
        config_dir=cfg_dir,
        state_file=state_file,
        akonadi=akonadi,
        keychain=keychain,
        gpg_runner=lambda _args: None,
    )

    ei = kp.KConfigFile.load(cfg_dir / "emailidentities")
    by_email = {
        ei.get(g, "Email Address"): g
        for g in ei.groups()
        if g.startswith("Identity #")
    }
    assert ei.get(by_email["alice@gmail.example"], "PGP Signing Key") == fprs["alice@gmail.example"]
    assert ei.get(by_email["alice@custom.example"], "PGP Encryption Key") == fprs["alice@custom.example"]


def test_identity_reconcile_leaves_non_numeric_groups_and_secondary_blank_identities_intact(
    tmp_path: Path,
) -> None:
    cfg_dir = tmp_path / "config"
    cfg_dir.mkdir()
    state_file = tmp_path / "state.json"

    (cfg_dir / "emailidentities").write_text(
        "[General]\n"
        "Default Identity=100\n\n"
        "[Identity #0]\n"
        "Default Domain=francis\n"
        "Identity=Default Blank\n"
        "Name=Default Blank\n"
        "uoid=100\n\n"
        "[Identity #2]\n"
        "Identity=Custom Blank With Transport\n"
        "Transport=555\n"
        "uoid=200\n\n"
        "[Identity #Archive]\n"
        "Email Address=archive@example.com\n"
        "uoid=300\n",
        encoding="utf-8",
    )

    cfg_path = _write_json(tmp_path, _gmail_with_aliases_payload())
    kp.provision(
        config_path=cfg_path,
        config_dir=cfg_dir,
        state_file=state_file,
        akonadi=FakeAkonadiClient(),
        keychain=FakeKeychainClient(),
        gpg_runner=lambda _a: "",
    )

    ei = kp.KConfigFile.load(cfg_dir / "emailidentities")
    # Non-numeric group untouched
    assert "Identity #Archive" in ei.groups()
    assert ei.get("Identity #Archive", "Email Address") == "archive@example.com"
    # Secondary blank identity with Transport preserved at its original index
    assert "Identity #2" in ei.groups()
    assert ei.get("Identity #2", "uoid") == "200"
    # First-run placeholder (uoid=100) was removed
    all_uoids = {ei.get(g, "uoid") for g in ei.groups()}
    assert "100" not in all_uoids


def test_reserve_recorded_resources_before_fallback_matching(tmp_path: Path) -> None:
    cfg_dir = tmp_path / "config"
    cfg_dir.mkdir()
    state_file = tmp_path / "state.json"
    akonadi = FakeAkonadiClient()
    keychain = FakeKeychainClient()

    # Initial: account A owns res_0 with user=old@example.com
    p1 = _write_json(
        tmp_path,
        {
            "version": 1,
            "accounts": [
                {
                    "id": "acct_a",
                    "name": "Account A",
                    "provider": "gmail",
                    "email": "old@example.com",
                    "realName": "A",
                    "password": "aaaa bbbb cccc dddd",
                }
            ],
        },
        name="p1.json",
    )
    kp.provision(
        config_path=p1,
        config_dir=cfg_dir,
        state_file=state_file,
        akonadi=akonadi,
        keychain=keychain,
        gpg_runner=lambda _a: "",
    )
    res_a = json.loads(state_file.read_text(encoding="utf-8"))["managed"]["acct_a"]["resource_id"]

    # Edit: insert acct_b BEFORE acct_a with old@example.com, while acct_a changes to new@example.com
    p2 = _write_json(
        tmp_path,
        {
            "version": 1,
            "accounts": [
                {
                    "id": "acct_b",
                    "name": "Account B",
                    "provider": "gmail",
                    "email": "old@example.com",
                    "realName": "B",
                    "password": "eeee ffff gggg hhhh",
                },
                {
                    "id": "acct_a",
                    "name": "Account A",
                    "provider": "gmail",
                    "email": "new@example.com",
                    "realName": "A",
                    "password": "aaaa bbbb cccc dddd",
                },
            ],
        },
        name="p2.json",
    )
    kp.provision(
        config_path=p2,
        config_dir=cfg_dir,
        state_file=state_file,
        akonadi=akonadi,
        keychain=keychain,
        gpg_runner=lambda _a: "",
    )
    state2 = json.loads(state_file.read_text(encoding="utf-8"))["managed"]
    # acct_a kept its original resource; acct_b got a new resource instead of stealing res_a
    assert state2["acct_a"]["resource_id"] == res_a
    assert state2["acct_b"]["resource_id"] != res_a


def test_pending_restart_retries_after_failed_restart(tmp_path: Path) -> None:
    cfg_dir = tmp_path / "config"
    cfg_dir.mkdir()
    state_file = tmp_path / "state.json"
    cfg_path = _write_json(tmp_path, _gmail_with_aliases_payload())
    keychain = FakeKeychainClient()

    class FlakyRestartAkonadi(FakeAkonadiClient):
        def __init__(self) -> None:
            super().__init__()
            self.fail_next_restart = True

        def restart_resource(self, resource_id: str) -> None:
            if self.fail_next_restart:
                self.fail_next_restart = False
                raise kp.ProvisionError("transient restart failure")
            super().restart_resource(resource_id)

    akonadi = FlakyRestartAkonadi()

    # First run saves password + settings, fails on restart -> records pending_restart
    with pytest.raises(kp.ProvisionError):
        kp.provision(
            config_path=cfg_path,
            config_dir=cfg_dir,
            state_file=state_file,
            akonadi=akonadi,
            keychain=keychain,
            gpg_runner=lambda _a: "",
        )
    saved = json.loads(state_file.read_text(encoding="utf-8"))
    assert saved["managed"]["main"].get("pending_restart") is True

    # Second run sees settings & password unchanged, yet still retries restart and clears flag
    assert (
        kp.provision(
            config_path=cfg_path,
            config_dir=cfg_dir,
            state_file=state_file,
            akonadi=akonadi,
            keychain=keychain,
            gpg_runner=lambda _a: "",
        )
        == kp.EXIT_OK
    )
    assert len(akonadi.restarted) == 1
    saved2 = json.loads(state_file.read_text(encoding="utf-8"))
    assert not saved2["managed"]["main"].get("pending_restart", False)


def test_dry_run_does_not_start_akonadi_when_stopped(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    cfg_dir = tmp_path / "config"
    cfg_dir.mkdir()
    state_file = tmp_path / "state.json"
    cfg_path = _write_json(tmp_path, _gmail_with_aliases_payload())

    akonadictl_called = False

    def fake_run(args: list[str], **_kwargs: object) -> object:
        nonlocal akonadictl_called

        class _Res:
            def __init__(self, rc: int, out: str = "", err: str = "") -> None:
                self.returncode = rc
                self.stdout = out
                self.stderr = err

        if args[0] == "akonadictl":
            akonadictl_called = True
            return _Res(0)
        if "Locked" in args:
            return _Res(0, "false\n")
        if "localWallet" in args:
            return _Res(0, "kdewallet\n")
        if "isOpen" in args:
            return _Res(0, "true\n")
        return _Res(1, "", "Service not found")

    monkeypatch.setattr(kp.subprocess, "run", fake_run)

    rc = kp.provision(
        config_path=cfg_path,
        config_dir=cfg_dir,
        state_file=state_file,
        dry_run=True,
        wait_seconds=1,
        gpg_runner=lambda _a: "",
    )
    assert rc == kp.EXIT_OK
    assert akonadictl_called is False
    out = capsys.readouterr().out
    assert "Akonadi is not running" in out


def test_alias_switching_to_parent_smtp_retires_old_transport_for_prune(
    tmp_path: Path,
) -> None:
    cfg_dir = tmp_path / "config"
    cfg_dir.mkdir()
    state_file = tmp_path / "state.json"
    akonadi = FakeAkonadiClient()
    keychain = FakeKeychainClient()

    with_custom_smtp = _write_json(
        tmp_path,
        {
            "version": 1,
            "accounts": [
                {
                    "id": "main",
                    "name": "Main",
                    "provider": "gmail",
                    "email": "alice@gmail.example",
                    "realName": "Alice",
                    "password": "aaaa bbbb cccc dddd",
                    "aliases": [
                        {
                            "id": "domain",
                            "name": "Domain",
                            "email": "alice@custom.example",
                            "realName": "Alice",
                            "smtp": {
                                "host": "smtp.custom.example",
                                "port": 465,
                                "username": "alice@custom.example",
                                "password": "custom-pw",
                            },
                        }
                    ],
                }
            ],
        },
        name="custom.json",
    )
    kp.provision(
        config_path=with_custom_smtp,
        config_dir=cfg_dir,
        state_file=state_file,
        akonadi=akonadi,
        keychain=keychain,
        gpg_runner=lambda _a: "",
    )
    old_alias_tid = kp.stable_transport_id("domain")

    # Switch alias back to inheriting parent SMTP without --prune
    inherited_smtp = _write_json(
        tmp_path,
        {
            "version": 1,
            "accounts": [
                {
                    "id": "main",
                    "name": "Main",
                    "provider": "gmail",
                    "email": "alice@gmail.example",
                    "realName": "Alice",
                    "password": "aaaa bbbb cccc dddd",
                    "aliases": [
                        {
                            "id": "domain",
                            "name": "Domain",
                            "email": "alice@custom.example",
                            "realName": "Alice",
                        }
                    ],
                }
            ],
        },
        name="inherited.json",
    )
    kp.provision(
        config_path=inherited_smtp,
        config_dir=cfg_dir,
        state_file=state_file,
        prune=False,
        akonadi=akonadi,
        keychain=keychain,
        gpg_runner=lambda _a: "",
    )
    mid_state = json.loads(state_file.read_text(encoding="utf-8"))
    assert old_alias_tid in mid_state.get("retired_transport_ids", [])

    # Subsequent --prune removes the retired alias transport
    kp.provision(
        config_path=inherited_smtp,
        config_dir=cfg_dir,
        state_file=state_file,
        prune=True,
        akonadi=akonadi,
        keychain=keychain,
        gpg_runner=lambda _a: "",
    )
    mt = kp.KConfigFile.load(cfg_dir / "mailtransports")
    assert f"Transport {old_alias_tid}" not in mt.groups()
    end_state = json.loads(state_file.read_text(encoding="utf-8"))
    assert old_alias_tid not in end_state.get("retired_transport_ids", [])


def test_kde_session_readiness_requires_kwallet_open_even_if_secret_service_unlocked(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("KDE_FULL_SESSION", "true")
    monkeypatch.delenv("QTKEYCHAIN_BACKEND", raising=False)

    def fake_run(args: list[str], **_kwargs: object) -> object:
        class _Res:
            def __init__(self, rc: int, out: str = "", err: str = "") -> None:
                self.returncode = rc
                self.stdout = out
                self.stderr = err

        if "Locked" in args:
            return _Res(0, "false\n")  # Secret Service unlocked
        if any("networkWallet" in a for a in args):
            return _Res(0, "kdewallet\n")
        if any("isOpen" in a for a in args):
            return _Res(0, "false\n")  # KWallet still locked!
        return _Res(1)

    monkeypatch.setattr(kp.subprocess, "run", fake_run)
    monkeypatch.setattr(kp.time, "sleep", lambda _s: None)
    now = [0.0]
    monkeypatch.setattr(
        kp.time, "monotonic", lambda: (now.__setitem__(0, now[0] + 0.6) or now[0])
    )

    client = kp.KeychainClient()
    with pytest.raises(kp.SessionNotReadyError):
        client.ensure_ready(wait_seconds=1)


def test_keychain_client_distinguishes_permanent_vs_retryable_exit_codes(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    def fake_run(args: list[str], **_kwargs: object) -> object:
        class _Res:
            def __init__(self, rc: int, out: str = "", err: str = "") -> None:
                self.returncode = rc
                self.stdout = out
                self.stderr = err

        if args[2] == "retryable":
            return _Res(3, "", "kmail-keychain-set: backend unavailable")
        return _Res(1, "", "kmail-keychain-set: keychain permanent error")

    monkeypatch.setattr(kp.subprocess, "run", fake_run)
    client = kp.KeychainClient()
    with pytest.raises(kp.SessionNotReadyError):
        client.set_password("mailtransports", "retryable", "pw")
    with pytest.raises(kp.ProvisionError):
        client.set_password("mailtransports", "perm", "pw")


# ---------------------------------------------------------------------------
# Regression tests for PR #14 Round 2 CodeRabbit review findings
# ---------------------------------------------------------------------------


def test_kwallet_readiness_probes_network_wallet(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("KDE_FULL_SESSION", "true")
    monkeypatch.delenv("QTKEYCHAIN_BACKEND", raising=False)
    calls: list[list[str]] = []

    def fake_run(args: list[str], **_kwargs: object) -> object:
        calls.append(args)

        class _Res:
            def __init__(self, rc: int, out: str = "", err: str = "") -> None:
                self.returncode = rc
                self.stdout = out
                self.stderr = err

        if any("networkWallet" in a for a in args):
            return _Res(0, "kdewallet\n")
        if any("isOpen" in a for a in args):
            return _Res(0, "true\n")
        return _Res(1)

    monkeypatch.setattr(kp.subprocess, "run", fake_run)
    kp.KeychainClient().ensure_ready(wait_seconds=1)
    assert any("networkWallet" in a for c in calls for a in c)
    assert not any("localWallet" in a for c in calls for a in c)


def test_customized_blank_first_run_identity_is_preserved(tmp_path: Path) -> None:
    cfg_dir = tmp_path / "config"
    cfg_dir.mkdir()
    state_file = tmp_path / "state.json"

    # Single identity with blank Email Address, but customized Reply-To & Inline Signature
    (cfg_dir / "emailidentities").write_text(
        "[General]\n"
        "Default Identity=505\n\n"
        "[Identity #0]\n"
        "Identity=Custom Draft Identity\n"
        "Name=Joel Benway\n"
        "Reply-To Address=reply@custom.example\n"
        "Signature Enabled=true\n"
        "Inline Signature=-- Custom Sig\n"
        "uoid=505\n",
        encoding="utf-8",
    )

    cfg_path = _write_json(tmp_path, _gmail_with_aliases_payload())
    kp.provision(
        config_path=cfg_path,
        config_dir=cfg_dir,
        state_file=state_file,
        akonadi=FakeAkonadiClient(),
        keychain=FakeKeychainClient(),
        gpg_runner=lambda _a: "",
    )

    ei = kp.KConfigFile.load(cfg_dir / "emailidentities")
    assert "Identity #0" in ei.groups()
    assert ei.get("Identity #0", "uoid") == "505"
    assert ei.get("Identity #0", "Reply-To Address") == "reply@custom.example"


def test_failed_gpg_lookup_after_email_change_clears_stale_pgp_binding(
    tmp_path: Path,
) -> None:
    cfg_dir = tmp_path / "config"
    cfg_dir.mkdir()
    state_file = tmp_path / "state.json"
    akonadi = FakeAkonadiClient()
    keychain = FakeKeychainClient()
    _, gpg_runner = _mock_gpg_for_three_identities()

    p1 = _write_json(tmp_path, _gmail_with_aliases_payload(), name="e1.json")
    kp.provision(
        config_path=p1,
        config_dir=cfg_dir,
        state_file=state_file,
        akonadi=akonadi,
        keychain=keychain,
        gpg_runner=gpg_runner,
    )

    # Change 'domain' alias email while keeping its slug, AND fail GPG lookup
    changed = _gmail_with_aliases_payload()
    changed["accounts"][0]["aliases"][0]["email"] = "newaddr@other.example"
    p2 = _write_json(tmp_path, changed, name="e2.json")
    kp.provision(
        config_path=p2,
        config_dir=cfg_dir,
        state_file=state_file,
        akonadi=akonadi,
        keychain=keychain,
        gpg_runner=lambda _args: None,
    )

    ei = kp.KConfigFile.load(cfg_dir / "emailidentities")
    by_email = {
        ei.get(g, "Email Address"): g
        for g in ei.groups()
        if g.startswith("Identity #")
    }
    grp = by_email["newaddr@other.example"]
    assert ei.get(grp, "PGP Signing Key") is None
    assert ei.get(grp, "PGP Encryption Key") is None
    assert ei.get(grp, "Override Encryption Defaults") == "false"


def test_create_resource_checkpoint_recovers_after_readiness_timeout(
    tmp_path: Path,
) -> None:
    cfg_dir = tmp_path / "config"
    cfg_dir.mkdir()
    state_file = tmp_path / "state.json"
    cfg_path = _write_json(tmp_path, _gmail_with_aliases_payload())
    keychain = FakeKeychainClient()

    class TimeoutAfterCreateAkonadi(FakeAkonadiClient):
        def __init__(self) -> None:
            super().__init__()
            self.fail_first_create = True

        def create_imap_resource(self, wait_seconds: int, on_created=None) -> str:
            res_id = super().create_imap_resource(wait_seconds)
            if on_created is not None:
                on_created(res_id)
            if self.fail_first_create:
                self.fail_first_create = False
                raise kp.SessionNotReadyError("resource /Settings timed out")
            return res_id

    akonadi = TimeoutAfterCreateAkonadi()

    with pytest.raises(kp.SessionNotReadyError):
        kp.provision(
            config_path=cfg_path,
            config_dir=cfg_dir,
            state_file=state_file,
            akonadi=akonadi,
            keychain=keychain,
            gpg_runner=lambda _a: "",
        )
    assert len(akonadi.created) == 1
    first_id = akonadi.created[0]

    # Retry reuses checkpointed ID instead of creating a second resource
    assert (
        kp.provision(
            config_path=cfg_path,
            config_dir=cfg_dir,
            state_file=state_file,
            akonadi=akonadi,
            keychain=keychain,
            gpg_runner=lambda _a: "",
        )
        == kp.EXIT_OK
    )
    assert akonadi.created == [first_id]


def test_pending_save_replays_imap_settings_save_even_when_live_values_match(
    tmp_path: Path,
) -> None:
    cfg_dir = tmp_path / "config"
    cfg_dir.mkdir()
    state_file = tmp_path / "state.json"
    cfg_path = _write_json(tmp_path, _gmail_with_aliases_payload())
    keychain = FakeKeychainClient()

    class FlakySaveAkonadi(FakeAkonadiClient):
        def __init__(self) -> None:
            super().__init__()
            self.fail_first_save = True

        def apply_imap_settings(self, resource_id: str, settings: dict[str, object]) -> None:
            # Setters mutate live object BEFORE save() fails
            self.resources[resource_id].update(settings)
            self.applied.append((resource_id, dict(settings)))
            if self.fail_first_save:
                self.fail_first_save = False
                raise kp.ProvisionError("save() D-Bus call failed")

    akonadi = FlakySaveAkonadi()
    with pytest.raises(kp.ProvisionError):
        kp.provision(
            config_path=cfg_path,
            config_dir=cfg_dir,
            state_file=state_file,
            akonadi=akonadi,
            keychain=keychain,
            gpg_runner=lambda _a: "",
        )
    assert len(akonadi.applied) == 1
    saved = json.loads(state_file.read_text(encoding="utf-8"))
    assert saved["managed"]["main"].get("pending_save") is True

    # Next run: live values already match, yet pending_save forces apply_imap_settings (save) replay
    assert (
        kp.provision(
            config_path=cfg_path,
            config_dir=cfg_dir,
            state_file=state_file,
            akonadi=akonadi,
            keychain=keychain,
            gpg_runner=lambda _a: "",
        )
        == kp.EXIT_OK
    )
    assert len(akonadi.applied) == 2
    saved2 = json.loads(state_file.read_text(encoding="utf-8"))
    assert not saved2["managed"]["main"].get("pending_save", False)


def test_pending_restart_checkpointed_before_password_write_commits(
    tmp_path: Path,
) -> None:
    cfg_dir = tmp_path / "config"
    cfg_dir.mkdir()
    state_file = tmp_path / "state.json"
    cfg_path = _write_json(tmp_path, _gmail_with_aliases_payload())
    akonadi = FakeAkonadiClient()

    # Initial clean provision
    keychain = FakeKeychainClient()
    kp.provision(
        config_path=cfg_path,
        config_dir=cfg_dir,
        state_file=state_file,
        akonadi=akonadi,
        keychain=keychain,
        gpg_runner=lambda _a: "",
    )

    # Rotate password, and crash right AFTER IMAP password commits to keychain
    rotated = _gmail_with_aliases_payload()
    rotated["accounts"][0]["password"] = "newp assw ord1 2345"
    cfg_path.write_text(json.dumps(rotated), encoding="utf-8")

    class CrashAfterImapCommitKeychain(FakeKeychainClient):
        def set_password(self, service: str, key: str, password: str) -> bool:
            changed = super().set_password(service, key, password)
            if service == "imap":
                # Verify pending_restart was ALREADY persisted to disk before commit
                st = json.loads(state_file.read_text(encoding="utf-8"))
                assert st["managed"]["main"].get("pending_restart") is True
                raise kp.ProvisionError("simulated crash right after commit")
            return changed

    crash_kc = CrashAfterImapCommitKeychain()
    crash_kc.secrets = dict(keychain.secrets)

    with pytest.raises(kp.ProvisionError):
        kp.provision(
            config_path=cfg_path,
            config_dir=cfg_dir,
            state_file=state_file,
            akonadi=akonadi,
            keychain=crash_kc,
            gpg_runner=lambda _a: "",
        )

    # Next run sees unchanged password in wallet, yet still restarts resource
    akonadi.reset_counters()
    stable_kc = FakeKeychainClient()
    stable_kc.secrets = dict(crash_kc.secrets)
    assert (
        kp.provision(
            config_path=cfg_path,
            config_dir=cfg_dir,
            state_file=state_file,
            akonadi=akonadi,
            keychain=stable_kc,
            gpg_runner=lambda _a: "",
        )
        == kp.EXIT_OK
    )
    assert len(akonadi.restarted) == 1


def test_dry_run_proceeds_when_wallet_is_locked(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    cfg_dir = tmp_path / "config"
    cfg_dir.mkdir()
    state_file = tmp_path / "state.json"
    cfg_path = _write_json(tmp_path, _gmail_with_aliases_payload())

    locked_kc = FakeKeychainClient(ready_error=kp.SessionNotReadyError("wallet locked"))
    rc = kp.provision(
        config_path=cfg_path,
        config_dir=cfg_dir,
        state_file=state_file,
        dry_run=True,
        akonadi=FakeAkonadiClient(),
        keychain=locked_kc,
        gpg_runner=lambda _a: "",
    )
    assert rc == kp.EXIT_OK
    out = capsys.readouterr().out
    assert "mailtransports" in out


def test_config_reloaded_under_lock_picks_up_rotated_secret(tmp_path: Path) -> None:
    cfg_dir = tmp_path / "config"
    cfg_dir.mkdir()
    state_file = tmp_path / "state.json"
    cfg_path = _write_json(tmp_path, _gmail_with_aliases_payload())
    akonadi = FakeAkonadiClient()

    class RotateDuringEnsureReadyKeychain(FakeKeychainClient):
        def ensure_ready(self, wait_seconds: int) -> None:
            rotated = _gmail_with_aliases_payload()
            rotated["accounts"][0]["password"] = "rota tedp assw 0000"
            cfg_path.write_text(json.dumps(rotated), encoding="utf-8")

    keychain = RotateDuringEnsureReadyKeychain()
    assert (
        kp.provision(
            config_path=cfg_path,
            config_dir=cfg_dir,
            state_file=state_file,
            akonadi=akonadi,
            keychain=keychain,
            gpg_runner=lambda _a: "",
        )
        == kp.EXIT_OK
    )
    res_id = akonadi.created[0]
    assert keychain.secrets[("imap", f"{res_id}rc")] == "rotatedpassw0000"


def test_adopted_resource_removed_from_retired_account_entry(tmp_path: Path) -> None:
    cfg_dir = tmp_path / "config"
    cfg_dir.mkdir()
    state_file = tmp_path / "state.json"
    akonadi = FakeAkonadiClient()
    keychain = FakeKeychainClient()

    # Step 1: provision account A
    p1 = _write_json(
        tmp_path,
        {
            "version": 1,
            "accounts": [
                {
                    "id": "acct_a",
                    "name": "A",
                    "provider": "gmail",
                    "email": "same@example.com",
                    "realName": "A",
                    "password": "aaaa bbbb cccc dddd",
                }
            ],
        },
        name="r1.json",
    )
    kp.provision(
        config_path=p1,
        config_dir=cfg_dir,
        state_file=state_file,
        akonadi=akonadi,
        keychain=keychain,
        gpg_runner=lambda _a: "",
    )
    res_id = akonadi.created[0]

    # Step 2: rename acct_a -> acct_b (same endpoint) without --prune
    p2 = _write_json(
        tmp_path,
        {
            "version": 1,
            "accounts": [
                {
                    "id": "acct_b",
                    "name": "B",
                    "provider": "gmail",
                    "email": "same@example.com",
                    "realName": "B",
                    "password": "aaaa bbbb cccc dddd",
                }
            ],
        },
        name="r2.json",
    )
    kp.provision(
        config_path=p2,
        config_dir=cfg_dir,
        state_file=state_file,
        prune=False,
        akonadi=akonadi,
        keychain=keychain,
        gpg_runner=lambda _a: "",
    )
    st = json.loads(state_file.read_text(encoding="utf-8"))["managed"]
    assert st["acct_b"]["resource_id"] == res_id
    # Retired acct_a keeps transport/identity IDs for later prune, but drops adopted resource_id
    assert "resource_id" not in st["acct_a"]
    assert st["acct_a"]["transport_id"] == kp.stable_transport_id("acct_a")
    assert st["acct_a"]["identity_uoid"] == kp.stable_identity_uoid("acct_a")
