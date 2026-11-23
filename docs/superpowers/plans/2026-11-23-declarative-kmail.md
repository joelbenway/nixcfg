# Declarative KMail Provisioning Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a zero-touch, secret-safe declarative KMail provisioner (`pkgs/kmail-provision` + `modules/kmail.nix` + `users/joel.nix` wiring + operator howto) that provisions Gmail/custom IMAP, SMTP, KMail identities (including Send-As aliases with automatic Kleopatra/GnuPG key binding), and QtKeychain credentials from an `agenix`-encrypted JSON file.

**Architecture:** An `agenix`-decrypted JSON file (`/run/agenix/<user>-kmail.json`, mode `0400`) is reconciled at Plasma login and on secret updates by a Home Manager `systemd --user` oneshot service + path watcher. The Python CLI (`kmail-provision`) parses presets/aliases, resolves GPG secret keys, atomically merges KConfig files (`mailtransports`, `emailidentities`, `emaildefaults`), reconciles Akonadi IMAP resources over D-Bus (`org.freedesktop.Akonadi.Control` + `org.kde.Akonadi.Imap.Settings`), and writes credentials via a minimal C++17 Qt6 helper (`kmail-keychain-set`) linked against `pkgs.qt6Packages.qtkeychain`.

**Tech Stack:** NixOS / Home Manager, Python 3 (stdlib only) + `pytest`, C++17 + Qt6 (`qtbase`, `qt6Packages.qtkeychain`), KDE PIM 26.08.2 (`qdbus`, `akonadictl`), GnuPG (`gpg`), Agenix.

**Spec:** [`docs/superpowers/specs/2026-11-23-declarative-kmail-design.md`](../specs/2026-11-23-declarative-kmail-design.md)

## Global Constraints

- Zero personal email addresses, usernames, passwords, or real GPG fingerprints anywhere in public `nixcfg` (use placeholders like `alice@example.com` in tests and docs).
- Never symlink `~/.config/mailtransports`, `~/.config/emailidentities`, `~/.config/emaildefaults`, or Akonadi `.rc` files into `/nix/store`; always merge mutable files atomically with `0600` permissions.
- Passwords must travel strictly over `stdin` to `kmail-keychain-set`, never in CLI args, logs (including `--dry-run` and error tracebacks), `mailtransports`, or `state.json`.
- QtKeychain targets verified against KDE PIM 26.08.2: SMTP uses `service="mailtransports"`, `key=str(transport_id)`; IMAP uses `service="imap"`, `key=f"{resource_id}rc"`.
- Akonadi `org.kde.Akonadi.Imap.Settings.setAuthentication(int)` uses `MailTransport::TransportBase::EnumAuthenticationType` integer values: `LOGIN=0, PLAIN=1, CRAM_MD5=2, DIGEST_MD5=3, GSSAPI=4, NTLM=5, APOP=6, CLEAR=7, ANONYMOUS=8, XOAUTH2=9`.
- Akonadi `setSafety(str)` accepts `"SSL"`, `"STARTTLS"`, or `"None"`.
- `mailtransports` `encryption` accepts `"SSL"`, `"TLS"`, or `"None"`; `authtype` accepts `"PLAIN"`, `"LOGIN"`, `"CRAM_MD5"`, `"DIGEST_MD5"`, `"GSSAPI"`, `"NTLM"`, `"APOP"`, `"CLEAR"`, `"ANONYMOUS"`, `"XOAUTH2"`.
- Must be CI-safe (`nix flake check`, `nix eval` across `agnes`, `francis`, `jerome`, `michael`, `zita`, `alejandra --check .`, `statix check .`) even when `secrets/joel-kmail.json.age` does not exist yet.
- All new Nix files must include the `# Copyright (c) Joel Benway` / `# SPDX-License-Identifier: MIT` header and pass `alejandra` and `statix`.

## Review Focus

- **Duplicate IDs or invalid `defaultAccount` / `defaultIdentity` references** — must raise a clear `ConfigError` before mutating any file, D-Bus resource, or keychain entry (pinned in Task 1).
- **Existing KConfig files with KDE syntax (`Path[$e]=...`, mixed-case keys with spaces like `Email Address`, unmanaged sections, and blank first-run default identity)** — must preserve unmanaged groups and exact key casing verbatim while replacing only a blank first-run default identity (pinned in Task 2).
- **Password leakage in `--dry-run` output, error messages, or `state.json`** — raw passwords must never appear in stdout, stderr, or persisted state even when keychain/D-Bus calls fail (pinned in Task 2).
- **Session not ready / wallet locked on Plasma startup** — must poll up to `--wait-seconds` and exit with distinct exit code `2` without corrupting config files or writing partial `state.json` (pinned in Task 2).
- **Missing `state.json` or manually deleted Akonadi IMAP resource** — must match live Akonadi IMAP resources by `(imapServer, userName)` to avoid duplicates when `state.json` is lost, and recreate a resource cleanly if the recorded `resource_id` was deleted in KMail (pinned in Task 2).

---

### Task 1: Schema Parsing, Provider Presets, Deterministic IDs & GPG Auto-Matching

**Files:**
- Create: `pkgs/kmail-provision/kmail_provision.py`
- Test: `pkgs/kmail-provision/test_kmail_provision.py`

**Interfaces:**
- Consumes: Python 3 stdlib (`dataclasses`, `hashlib`, `json`, `pathlib`, `subprocess`, `typing`).
- Produces (in `pkgs/kmail-provision/kmail_provision.py`):
  - `EXIT_OK = 0`, `EXIT_CONFIG_ERROR = 1`, `EXIT_SESSION_NOT_READY = 2`, `EXIT_PROVISION_ERROR = 3`
  - `ConfigError(Exception)`, `SessionNotReadyError(Exception)`, `ProvisionError(Exception)`
  - `IMAP_AUTH_ENUM: dict[str, int]` (exact `MailTransport::TransportBase::EnumAuthenticationType` map)
  - Dataclasses: `ImapConfig`, `SmtpConfig`, `GpgConfig`, `IdentitySpec`, `AccountSpec`, `ProvisionConfig`
  - `stable_transport_id(slug: str) -> int` (range `100_000..999_999_998`)
  - `stable_identity_uoid(slug: str) -> int` (range `100_000_000..2_099_999_999`)
  - `load_config(path: Path) -> ProvisionConfig`
  - `resolve_gpg_fingerprint(email: str, gpg_cfg: GpgConfig | None, gpg_runner: Callable[[list[str]], str] | None = None) -> str | None`

- [ ] **Step 1: Write failing tests for config parsing, presets, aliases, deterministic IDs, and GPG matching**

Create `pkgs/kmail-provision/test_kmail_provision.py` with tests covering:
- `test_gmail_preset_defaults_and_password_normalization`: loads a minimal `"provider": "gmail"` account with spaces in `password` (`"abcd efgh ijkl mnop"`), asserts `imap` defaults to `imap.gmail.com:993` / `SSL` / `PLAIN` / `interval_check_minutes=5` / `disconnected_mode=True`, `smtp` defaults to `smtp.gmail.com:465` / `SSL` / `PLAIN`, `disable_fcc=True`, and both passwords have spaces stripped to `"abcdefghijklmnop"`.
- `test_custom_provider_preserves_password_spaces_and_requires_hosts`: asserts `"provider": "custom"` preserves internal spaces verbatim, defaults `disable_fcc=False`, and raises `ConfigError` when `imap.host` or `smtp.host` is missing.
- `test_aliases_inherit_parent_transport_and_default_identity_can_target_alias`: configures one Gmail account (`id="main"`) with two aliases (`id="domain"`, `id="alt"`) and `"defaultIdentity": "domain"`; asserts aliases inherit parent `transport_id` and `disable_fcc=True`, have distinct deterministic `uoid`s, `default_transport_id == main.transport_id`, and `default_identity_uoid == domain.uoid`. Also verifies an alias with its own `smtp` block gets its own `transport_id` and `SmtpConfig`.
- `test_validation_rejects_bad_version_duplicate_ids_and_unknown_defaults`: asserts `ConfigError` for `version != 1`, empty `accounts`, duplicate `id` across accounts/aliases, unknown `defaultAccount`, unknown `defaultIdentity`, or unsupported `auth`/`safety`/`encryption`.
- `test_stable_ids_are_deterministic_and_in_valid_ranges`: asserts repeated calls return identical positive 31-bit ints within spec ranges.
- `test_gpg_auto_match_unique_ambiguous_missing_and_revoked_expired`: passes mock `gpg --list-secret-keys --with-colons` output containing (a) one valid key matching `alice@example.com` (case-insensitive) -> returns 40-char uppercase fingerprint, (b) two valid keys matching `dup@example.com` -> returns `None` (logs warning), (c) revoked (`r`) and expired (`e`) keys for `old@example.com` -> ignored, returns `None`, (d) explicit fingerprint -> returned directly without calling `gpg`, (e) `gpg=None` or `enable=False` -> returns `None`.

- [ ] **Step 2: Run pytest to verify tests fail**

Run: `pytest pkgs/kmail-provision/test_kmail_provision.py -v`
Expected: FAIL with `ModuleNotFoundError: No module named 'kmail_provision'`

- [ ] **Step 3: Implement schema, presets, ID derivation, and GPG matching in `pkgs/kmail-provision/kmail_provision.py`**

Implement the dataclasses, constants, `stable_transport_id`, `stable_identity_uoid`, `load_config`, and `resolve_gpg_fingerprint` in `pkgs/kmail-provision/kmail_provision.py`:
- `load_config` validates `version == 1`, non-empty `accounts`, unique slugs across all accounts and aliases, collision-free derived `transport_id`s and `identity_uoid`s, valid `defaultAccount` / `defaultIdentity`, and provider-specific defaults (`gmail` vs `custom`).
- `resolve_gpg_fingerprint` parses `gpg --list-secret-keys --with-colons` records (`sec`, `fpr`, `uid`), tracking the current primary key validity (skipping `sec` entries with trust/validity `r`, `e`, `d` and `uid` entries with validity `r`, `e`, `d`), extracting `<email>` from UIDs, and returning the fingerprint only when exactly one valid primary key matches.

- [ ] **Step 4: Run pytest to verify Task 1 tests pass**

Run: `pytest pkgs/kmail-provision/test_kmail_provision.py -v`
Expected: All Task 1 tests PASS.

- [ ] **Step 5: Commit Task 1**

```bash
git add pkgs/kmail-provision/kmail_provision.py pkgs/kmail-provision/test_kmail_provision.py
git commit -m "feat(kmail-provision): add config schema, presets, deterministic IDs, and GPG auto-matching"
```

---

### Task 2: KConfig Merging, Akonadi/Keychain Adapters, State Store & Provisioner CLI

**Files:**
- Modify: `pkgs/kmail-provision/kmail_provision.py`
- Test: `pkgs/kmail-provision/test_kmail_provision.py`

**Interfaces:**
- Consumes: All Task 1 types and functions in `pkgs/kmail-provision/kmail_provision.py`.
- Produces (in `pkgs/kmail-provision/kmail_provision.py`):
  - `KConfigFile`: `load(path: Path) -> KConfigFile`, `groups() -> list[str]`, `get(group: str, key: str, default: str | None = None) -> str | None`, `set(group: str, key: str, value: str) -> bool` (returns `True` if changed), `remove_group(group: str) -> bool`, `save_atomic(path: Path) -> None` (temp file + `0o600` + `os.replace`)
  - `StateStore`: `load(path: Path) -> dict`, `save(path: Path, state: dict) -> None` (`0o600`, IDs only)
  - `AkonadiClient` protocol/class: `ensure_ready(wait_seconds: int) -> None`, `list_imap_resources() -> list[str]`, `get_imap_settings(resource_id: str) -> dict[str, Any]`, `create_imap_resource(wait_seconds: int) -> str`, `apply_imap_settings(resource_id: str, settings: dict[str, Any]) -> None`, `restart_resource(resource_id: str) -> None`, `remove_resource(resource_id: str) -> None`
  - `KeychainClient` protocol/class: `ensure_ready(wait_seconds: int) -> None`, `set_password(service: str, key: str, password: str) -> bool` (returns `True` if written/changed, passes password strictly on `stdin` to `kmail-keychain-set`)
  - `reconcile_mailtransports(cfg: ProvisionConfig, config_dir: Path, state: dict, keychain: KeychainClient, dry_run: bool, prune: bool) -> list[str]`
  - `reconcile_emailidentities(cfg: ProvisionConfig, config_dir: Path, state: dict, gpg_runner: Callable[[list[str]], str] | None, dry_run: bool, prune: bool) -> tuple[list[str], dict[str, int]]`
  - `reconcile_imap_resources(cfg: ProvisionConfig, state: dict, akonadi: AkonadiClient, keychain: KeychainClient, dry_run: bool, prune: bool, wait_seconds: int) -> list[str]`
  - `provision(config_path: Path, config_dir: Path, state_file: Path, dry_run: bool = False, prune: bool = False, wait_seconds: int = 30, akonadi: AkonadiClient | None = None, keychain: KeychainClient | None = None, gpg_runner: Callable[[list[str]], str] | None = None) -> int`
  - `main(argv: list[str] | None = None) -> int`

- [ ] **Step 1: Write failing tests for KConfig merging, Akonadi/Keychain reconciliation, idempotency, dry-run, pruning, and failure modes**

Append tests to `pkgs/kmail-provision/test_kmail_provision.py` using lightweight in-memory `FakeAkonadiClient` and `FakeKeychainClient` fakes:
- `test_kconfig_preserves_case_kde_syntax_and_unmanaged_groups`: parses an existing INI containing `Path[$e]=$HOME/.local/share/local-mail`, mixed-case keys (`Email Address`, `Disable Fcc`), and unmanaged sections; modifies one managed group and asserts unmanaged groups, exact casing, and `[$e]` lines are byte-preserved and file mode is `0o600`.
- `test_provision_replaces_blank_firstrun_identity_and_preserves_unmanaged`: seeds `emailidentities` with francis's blank default (`Default Domain=francis`, no `Email Address`) plus a manually created `[Identity #1]` (`Email Address=manual@other.example`) and unmanaged `[Transport 999]`; runs `provision()` with 1 Gmail account + 2 aliases (`defaultIdentity` = alias #1) + mock GPG keys. Asserts:
  - Blank default identity is replaced (no orphaned nameless identity remains).
  - Manual identity and `[Transport 999]` remain intact.
  - All 3 managed identities have `Disable Fcc=true`, `Transport=<gmail_tid>`, matching `PGP Signing Key` / `PGP Encryption Key`, `Preferred Crypto Message Format=openpgp/mime`, and `[General] Default Identity=<alias1_uoid>`.
  - `emaildefaults` has `[PROFILE_Default]` updated to alias #1's email and name.
  - `mailtransports` has `[Transport <gmail_tid>]` with `host=smtp.gmail.com`, `port=465`, `encryption=SSL`, `authtype=PLAIN`, `auth=true`, `storepass=true`, and `[General] default=<gmail_tid>`.
  - Akonadi created 1 IMAP resource with `ImapServer=imap.gmail.com`, `ImapPort=993`, `Safety=SSL`, `Authentication=1` (`PLAIN`), `AccountIdentity=<main_uoid>`, `UseDefaultIdentity=false`.
  - Keychain received `("mailtransports", str(gmail_tid), password)` and `("imap", f"{res_id}rc", password)`.
- `test_provision_second_run_is_strict_noop`: runs `provision()` twice back-to-back; asserts second run calls `create_imap_resource` 0 times, `apply_imap_settings` 0 times, `restart_resource` 0 times, and writes 0 keychain updates.
- `test_provision_recovers_when_state_file_missing_or_resource_deleted`:
  - Subcase A: deletes `state.json` while `FakeAkonadiClient` still has the existing IMAP resource -> asserts `provision()` matches by `(imapServer, userName)` and reuses it without creating a duplicate.
  - Subcase B: deletes the IMAP resource from `FakeAkonadiClient` while `state.json` still lists it -> asserts `provision()` creates a fresh IMAP resource and updates `state.json`.
- `test_dry_run_makes_no_mutations_and_redacts_passwords`: runs `provision(..., dry_run=True)` capturing stdout/stderr; asserts zero files written, zero Akonadi mutations, zero keychain writes, and the secret password substring does not appear anywhere in output.
- `test_prune_removes_only_managed_entries`: provisions 2 accounts, removes 1 from JSON, runs with `prune=True` alongside an unmanaged account/transport/identity; asserts only the removed managed resource, transport, and identity are deleted while unmanaged ones stay untouched.
- `test_session_not_ready_returns_exit_code_2_without_mutating_state`: configures `FakeKeychainClient.ensure_ready` to raise `SessionNotReadyError`; asserts `main()` returns `2`, writes no `state.json`, and does not leak passwords in stderr.
- `test_state_file_contains_no_passwords_and_has_0600_mode`: asserts `state.json` permissions are `0o600` and serialized JSON contains neither the raw nor normalized password.

- [ ] **Step 2: Run pytest to verify new tests fail**

Run: `pytest pkgs/kmail-provision/test_kmail_provision.py -v`
Expected: New tests FAIL with `ImportError` / `AttributeError`.

- [ ] **Step 3: Implement `KConfigFile`, `StateStore`, `AkonadiClient`, `KeychainClient`, reconcilers, `provision()`, and `main()` in `pkgs/kmail-provision/kmail_provision.py`**

Key implementation details pinned by the spec:
- `KConfigFile`: custom line-preserving INI parser/serializer (not `configparser`) that tracks ordered sections and raw lines so unmanaged groups, comments, and `[$e]` suffixes survive untouched; writes via `tempfile.NamedTemporaryFile` in target dir with `os.chmod(0o600)` + `os.replace`.
- `AkonadiClient`: uses `qdbus` (`org.freedesktop.Akonadi.Control /AgentManager` and `org.freedesktop.Akonadi.Resource.<id> /Settings`) and `akonadictl start` if Akonadi isn't running yet, polling up to `wait_seconds`. Reads current `/Settings` getters before mutating so steady-state runs do zero writes/restarts.
- `KeychainClient`: polls `qdbus` for `org.freedesktop.secrets` or `org.kde.kwalletd6` up to `wait_seconds`, then invokes `kmail-keychain-set <service> <key>` with `input=password` on `stdin` (never in argv). `kmail-keychain-set` exits `0` and prints `unchanged` or `updated` on stdout (or exits non-zero on error) so `set_password()` accurately knows whether the password changed (triggering an Akonadi resource restart only when config or password actually changed).
- After updating `mailtransports` or `emailidentities`, if live D-Bus `org.kde.pim.TransportManager` / `org.kde.pim.IdentityManager` exist, optionally trigger best-effort notification (never failing if KMail isn't open).
- `main()` parses `--config`, `--state-file`, `--config-dir`, `--dry-run`, `--prune`, `--wait-seconds`, catches `ConfigError` (`EXIT_CONFIG_ERROR = 1`), `SessionNotReadyError` (`EXIT_SESSION_NOT_READY = 2`), and `ProvisionError` (`EXIT_PROVISION_ERROR = 3`), ensuring exception messages never include password strings.

- [ ] **Step 4: Run full pytest suite to verify all tests pass**

Run: `pytest pkgs/kmail-provision/test_kmail_provision.py -v`
Expected: All tests PASS (0 failures).

- [ ] **Step 5: Commit Task 2**

```bash
git add pkgs/kmail-provision/kmail_provision.py pkgs/kmail-provision/test_kmail_provision.py
git commit -m "feat(kmail-provision): add KConfig merger, Akonadi/keychain adapters, and idempotent CLI"
```

---

### Task 3: `kmail-keychain-set` C++ QtKeychain Helper & Nix Package

**Files:**
- Create: `pkgs/kmail-provision/kmail-keychain-set.cpp`
- Create: `pkgs/kmail-provision/default.nix`

**Interfaces:**
- Consumes: `pkgs.qt6.qtbase`, `pkgs.qt6Packages.qtkeychain`, `pkgs.qt6.qttools`, `pkgs.kdePackages.akonadi`, `pkgs.gnupg`, `pkgs.python3`, `pkgs.python3Packages.pytest`, and `pkgs/kmail-provision/kmail_provision.py`.
- Produces:
  - `pkgs/kmail-provision/default.nix` (`{pkgs}:` derivation returning a package with `$out/bin/kmail-keychain-set` and `$out/bin/kmail-provision`, with `doCheck = true` running `pytest`).
  - `kmail-keychain-set <service> <key>`: reads UTF-8 password from `stdin` (stripping a single trailing `\n` / `\r\n`), checks existing secret via `QKeychain::ReadPasswordJob` (exiting `0` printing `unchanged` if equal), otherwise writes via `QKeychain::WritePasswordJob` (exiting `0` printing `updated`, or non-zero printing error to stderr without ever printing the password).

- [ ] **Step 1: Write `pkgs/kmail-provision/kmail-keychain-set.cpp`**

Implement minimal C++17 `QCoreApplication` CLI (~60 lines) using `#include <qt6keychain/keychain.h>` (or `#include <qtkeychain/keychain.h>`—verify exact header path in `pkgs.qt6Packages.qtkeychain.dev` during build) executing synchronous `QEventLoop`-backed `ReadPasswordJob` then `WritePasswordJob` when needed. Never log the password.

- [ ] **Step 2: Write `pkgs/kmail-provision/default.nix`**

Create `pkgs/kmail-provision/default.nix` (with MIT SPDX header) using `pkgs.stdenv.mkDerivation` (with `dontWrapQtApps = true` or `qt6.wrapQtAppsHook`—prefer explicit `wrapProgram` or `makeWrapper` + `qt6.wrapQtAppsHook` so `kmail-keychain-set` resolves Qt plugins cleanly and `kmail-provision` has `PATH` containing `$out/bin`, `qt6.qttools`, `kdePackages.akonadi`, `gnupg`):
- `buildPhase`: compiles `kmail-keychain-set.cpp` with `c++ -std=c++17 -O2 -fPIC` using `pkg-config --cflags --libs Qt6Core` + `qt6keychain` include/lib flags.
- `doCheck = true`: runs `pytest -v test_kmail_provision.py` in `checkPhase`.
- `installPhase`: installs `kmail-keychain-set` and wrapped `kmail-provision` into `$out/bin/`.

- [ ] **Step 3: Build the Nix package and verify both binaries and sandboxed pytest**

Run:
```bash
nix build --impure --no-link --print-out-paths --expr 'let f = builtins.getFlake (toString ./.); pkgs = f.nixosConfigurations.francis.pkgs; in import ./pkgs/kmail-provision { inherit pkgs; }'
```
Then run `<out>/bin/kmail-provision --help` and `<out>/bin/kmail-keychain-set` (no args -> exits non-zero with usage message) and `alejandra --check pkgs/kmail-provision/default.nix` + `statix check pkgs/kmail-provision/default.nix`.
Expected: Build succeeds (including `pytest` in `checkPhase`), `--help` prints CLI flags, `kmail-keychain-set` prints usage and exits non-zero.

- [ ] **Step 4: Commit Task 3**

```bash
git add pkgs/kmail-provision/kmail-keychain-set.cpp pkgs/kmail-provision/default.nix
git commit -m "feat(kmail-provision): package kmail-keychain-set and kmail-provision with sandboxed pytest"
```

---

### Task 4: NixOS Module (`modules/kmail.nix`), User Wiring (`users/joel.nix`) & Operator Guide

**Files:**
- Create: `modules/kmail.nix`
- Modify: `users/joel.nix:51-95`
- Create: `docs/howto/declarative-kmail.md`

**Interfaces:**
- Consumes: `pkgs/kmail-provision/default.nix`, `config.plasma.enable`, `config.age.secrets`.
- Produces:
  - NixOS option `kmail.users.<name>.{enable, configFile, prune}` in `modules/kmail.nix` (auto-imported by `modules/default.nix`).
  - Home Manager `home.packages` (`kmail-provision`), `systemd.user.services.kmail-provision`, and `systemd.user.paths.kmail-provision` for enabled desktop users.
  - Guarded secret `age.secrets.joel-kmail-json` + `kmail.users.joel` wiring in `users/joel.nix`.

- [ ] **Step 1: Create `modules/kmail.nix`**

Follow `modules/gpg.nix` and `modules/hex.nix` conventions:
- Define `userConfigType` with `enable` (`mkEnableOption`), `configFile` (`nullOr (either path str)`), and `prune` (`bool`, default `false`).
- Build `kmailProvision = import ../pkgs/kmail-provision {inherit pkgs;};`.
- Under `config = lib.mkIf config.plasma.enable { home-manager.users = lib.mapAttrs ... config.kmail.users; };`:
  - When `cfg.enable && cfg.configFile != null`:
    - `home.packages = [kmailProvision];`
    - `systemd.user.services.kmail-provision`:
      - `Unit`: `Description = "Provision declarative KMail accounts"`, `After = ["graphical-session.target" "plasma-kwallet-pam.service"]`, `PartOf = ["graphical-session.target"]`, `ConditionPathExists = toString cfg.configFile`, `StartLimitIntervalSec = 0`
      - `Service`: `Type = "oneshot"`, `Restart = "no"`, `RestartForceExitStatus = [2]`, `RestartSec = "60s"`, `ExecStart = "${kmailProvision}/bin/kmail-provision --config ${lib.escapeShellArg (toString cfg.configFile)}${lib.optionalString cfg.prune " --prune"}"` (omits `RemainAfterExit=true` so `systemd.user.paths` re-triggers on secret updates)
      - `Install`: `WantedBy = ["graphical-session.target"]`
    - `systemd.user.paths.kmail-provision`:
      - `Unit`: `Description = "Watch declarative KMail config for updates"`, `PartOf = ["graphical-session.target"]`
      - `Path`: `PathChanged = toString cfg.configFile`, `Unit = "kmail-provision.service"`
      - `Install`: `WantedBy = ["graphical-session.target"]`

- [ ] **Step 2: Wire guarded agenix secret and `kmail.users.joel` in `users/joel.nix`**

In `users/joel.nix`, inside `extraConfig`:
- Compute `kmailSecretFile = lib.custom.relativeToRoot "secrets/${username}-kmail.json.age";` and `hasKmailSecret = builtins.pathExists kmailSecretFile;`.
- Merge `lib.mkIf (hasKmailSecret && config.${username}.desktop) { "${username}-kmail-json" = { file = kmailSecretFile; name = "${username}-kmail.json"; mode = "0400"; owner = username; group = "users"; }; }` into `age.secrets` (via `lib.mkMerge`) so headless hosts never attempt to decrypt it.
- Set:
  ```nix
  kmail.users = lib.mkIf (hasKmailSecret && config.${username}.desktop) {
    ${username} = {
      enable = true;
      configFile = config.age.secrets."${username}-kmail-json".path;
    };
  };
  ```
- Note on CI placeholder discovery (`.github/workflows/ci.yml:131`): the `secrets/${username}...` pattern matches `secrets/${username}-kmail.json.age`, so the fallback loop creates an empty `secrets/joel-kmail.json.age` when no SSH key is configured. On `agnes`, `francis`, and `jerome` (where `desktop` defaults to `true`), this exercises the enabled KMail branch; on `michael` and `zita` (`desktop = false`), both the secret and KMail service stay disabled.

- [ ] **Step 3: Write `docs/howto/declarative-kmail.md`**

Include:
- JSON schema reference with placeholder Gmail + Send-As aliases example (`alice@example.com`, `alice@custom.example`, `alias@duck.example`) showing `defaultIdentity`, `disableFcc`, and `"gpg": { "key": "auto" }`.
- Exact commands to add `"joel-kmail.json.age"` to `secrets/agenix-rules.nix` (`publicKeys = [keys.hosts.francis keys.hosts.agnes keys.hosts.jerome keys.joel];`) and encrypt with `agenix -e joel-kmail.json.age`.
- Verification commands: `kmail-provision --config /run/agenix/joel-kmail.json --dry-run`, `systemctl --user status kmail-provision.service`, `journalctl --user -u kmail-provision.service`, and checking KMail Accounts / Identities / Kleopatra GPG keys.

- [ ] **Step 4: Run full repo lint, format, and multi-host evaluation verification**

Run:
```bash
alejandra --check .
statix check .
for h in agnes francis jerome michael zita; do
  echo "=== $h ==="
  nix eval ".#nixosConfigurations.${h}.config.system.build.toplevel.drvPath"
done
```
Also verify that enabling `kmail.users.joel` evaluates cleanly on `francis` (and remains disabled on headless `zita` and `michael`).
Expected: Zero formatting/lint errors, all 5 hosts evaluate cleanly.

- [ ] **Step 5: Commit Task 4**

```bash
git add modules/kmail.nix users/joel.nix docs/howto/declarative-kmail.md
git commit -m "feat(kmail): add declarative KMail module, joel wiring, and setup guide"
```
