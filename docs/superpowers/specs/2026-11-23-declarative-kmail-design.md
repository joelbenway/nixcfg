# Declarative KMail Provisioning (Agenix JSON → Akonadi / KMail / QtKeychain) — Design Spec

- **Date:** 2026-11-23
- **Status:** Approved
- **Owner:** Joel Benway
- **Scope:** Zero-touch, secret-safe declarative KMail account provisioning across KDE Plasma 6 workstations (`francis`, `agnes`, `jerome`) using an `agenix`-encrypted JSON config, a reusable NixOS module (`modules/kmail.nix`), and an idempotent provisioning CLI (`pkgs/kmail-provision`).

---

## 1. Intent & Why

KMail is Joel's preferred desktop mail client because of its seamless integration with **Kleopatra** and `~/.gnupg` (already declaratively imported via `modules/gpg.nix`) for signing, encrypting, and receiving PGP email. However, `nixcfg` currently only installs the KDE PIM packages (`modules/plasma.nix`) without configuring any accounts.

Two constraints make off-the-shelf Nix/Home Manager email options unsuitable:
1. **Public repo privacy:** `nixcfg` is public while `secrets/` is a private `agenix`-encrypted submodule. Build-time Home Manager options (`accounts.email`) cannot evaluate `.age` files at build time without leaking addresses into `nixcfg` or moving plaintext Nix into `nixos-secrets`.
2. **Akonadi / KMail mutability:** KMail splits each account across `~/.config/emailidentities`, `~/.config/mailtransports`, Akonadi agent instances (`~/.config/akonadi/agentsrc` + `akonadi_imap_resource_*rc` + Akonadi DB), and **QtKeychain** (backed by Plasma 6's `ksecretd` / `kdewallet`). Akonadi mutates its `.rc` files at runtime, so read-only `/nix/store` symlinks break it.

Because Joel uses **Gmail with App Passwords** (no interactive OAuth2 browser dance required), a runtime provisioner reading an `agenix`-decrypted JSON file can configure KMail end-to-end—incoming IMAP, outgoing SMTP, identities with GPG key bindings, and keychain credentials—completely zero-touch across `francis`, `agnes`, and `jerome`.

---

## 2. Goals, Non-Goals, and Anti-Goals

### Goals
- Keep **100% of email metadata and secrets** (addresses, display names, usernames, hosts, app passwords, GPG fingerprints) inside `secrets/<user>-kmail.json.age`—zero personal email addresses or credentials in public `nixcfg`.
- Provision one or more email accounts (with a built-in `"gmail"` provider preset and generic `"custom"` IMAP/SMTP support) plus optional **send-as aliases** (additional KMail identities sharing a parent SMTP transport or specifying their own).
- Wire each identity cleanly to Joel's imported GnuPG/Kleopatra keys—supporting both explicit 40-char GPG fingerprints and `"auto"` matching against local `gpg --list-secret-keys` by email UID.
- Provision credentials into the exact **QtKeychain** (`libqt6keychain.so.1`) backend used by KDE PIM 26.08 (`akonadi_imap_resource` and `libKPim6MailTransport.so.6`) so KMail connects with zero password prompts on fresh workstations.
- Be **strictly idempotent**: re-running on every login, `nixos-rebuild switch`, or manual invocation updates managed accounts in place without duplicating Akonadi resources, SMTP transports, or identities.
- Preserve unmanaged/manually added KMail accounts, identities, and transports untouched.
- Support `--dry-run` (with redacted secrets) and comprehensive unit tests (`pytest`) with mocked D-Bus/KConfig/keychain adapters.
- Follow existing `nixcfg` per-user module conventions (`modules/gpg.nix`, `modules/loadkeys.nix`, `modules/hex.nix`) and remain CI-safe when the encrypted `.age` file does not yet exist.

### Non-Goals (Explicitly Deferred)
- OAuth2 interactive flows (Gmail/M365 XOAUTH2 browser login).
- Google Calendar (CalDAV) / Contacts (CardDAV) / Merkuro provisioning (can be added later as additional resource types in the same JSON schema).
- Declarative KMail sieve/message filter rules or folder layout customization (`kmail2rc` UI geometry).
- Enabling KMail provisioning for other users (`katy`, `eliza`) out of the box—though the module schema (`kmail.users.<name>`) supports any Plasma user cleanly.

### Anti-Goals
- **Symlinking mutable KDE/Akonadi `.rc` files into `/nix/store`:** Akonadi and KMail must remain free to write runtime state (folder IDs, sync timestamps, UI state) to their config files.
- **Leaking passwords into process arguments, logs, or state files:** Passwords must only travel over `stdin` to the keychain helper, must never be logged (even on error or `--dry-run`), and must never be written to `~/.local/share/kmail-provision/state.json` or `mailtransports`.
- **Clobbering or deleting manually created KMail accounts:** Reconciling managed accounts must never touch accounts not owned by `kmail-provision`, and pruning removed managed accounts is opt-in (`prune = false` by default).
- **Breaking headless hosts (`zita`, `michael`) or CI evaluation:** Must be a no-op when `plasma.enable` is false or the `.age` secret is absent.

---

## 3. Constraints & Verified KDE PIM 26.08.2 Interfaces

Recon against the installed KDE PIM 26.08.2 / Plasma 6 binaries on `francis` verified the exact interfaces this design targets:

1. **Akonadi Control D-Bus (`org.freedesktop.Akonadi.Control` at `/AgentManager`):**
   - `agentInstances() -> QStringList`
   - `agentInstanceType(QString id) -> QString`
   - `agentInstanceName(QString id) -> QString`
   - `createAgentInstance("akonadi_imap_resource") -> QString` (returns new resource ID, e.g. `akonadi_imap_resource_0`)
   - `restartAgentInstance(QString id)`
   - `removeAgentInstance(QString id)` (only used when pruning is explicitly enabled)
2. **Akonadi IMAP Resource D-Bus (`org.freedesktop.Akonadi.Resource.<id>` at `/Settings`, interface `org.kde.Akonadi.Imap.Settings`):**
   - `setName(s)`, `setImapServer(s)`, `setImapPort(i)`, `setUserName(s)`
   - `setSafety(s)` — accepts `"SSL"`, `"STARTTLS"`, or `"None"`
   - `setAuthentication(i)` — verified via `Settings::mapTransportAuthToKimap` to use `MailTransport::TransportBase::EnumAuthenticationType` integer values:
     - `0` = `LOGIN`, `1` = `PLAIN`, `2` = `CRAM_MD5`, `3` = `DIGEST_MD5`, `4` = `GSSAPI`, `5` = `NTLM`, `6` = `APOP`, `7` = `CLEAR`, `8` = `ANONYMOUS`, `9` = `XOAUTH2`
   - `setIntervalCheckEnabled(b)`, `setIntervalCheckTime(i)`, `setDisconnectedModeEnabled(b)`
   - `setUseDefaultIdentity(b)`, `setAccountIdentity(i)`
   - `save()`
3. **KMailTransport (`~/.config/mailtransports`, verified via `mailtransport.kcfg`):**
   - Group `[General]`: `default=<transport_id>`
   - Group `[Transport <transport_id>]`: `id`, `name`, `identifier=SMTP`, `host`, `port`, `user`, `auth=true`, `storepass=true`, `encryption=<SSL|TLS|None>`, `authtype=<PLAIN|LOGIN|CLEAR|...>`
4. **KIdentityManagement (`~/.config/emailidentities` & `~/.config/emaildefaults`):**
   - `[General]`: `Default Identity=<uoid>`
   - `[Identity #<n>]`: `Identity`, `Name`, `Email Address`, `Transport=<transport_id>`, `uoid=<uoid>`, `Disable Fcc=<bool>` (defaults to `true` for Gmail so Gmail's server-side `[Gmail]/Sent Mail` copy isn't duplicated locally), `Override Encryption Defaults=false`, and when GPG is bound: `PGP Signing Key=<40-char-fpr>`, `PGP Encryption Key=<40-char-fpr>`, `Pgp Auto Sign=<bool>`, `Pgp Auto Encrypt=<bool>`, `Preferred Crypto Message Format=openpgp/mime`, `Autocrypt=<bool>`
   - `~/.config/emaildefaults` `[PROFILE_Default]`: `EmailAddress`, `FullName`
5. **QtKeychain (`libqt6keychain.so.1`, `pkgs.qt6Packages.qtkeychain` 0.17.0 — verified via binary disassembly):**
   - **SMTP (`libKPim6MailTransport.so.6`):** `QKeychain::WritePasswordJob("mailtransports")` with `key = QString::number(transportId)` (e.g. `"100001"`).
   - **IMAP (`.akonadi_imap_resource-wrapped`):** `QKeychain::WritePasswordJob("imap")` with `key = config()->name()` (e.g. `"akonadi_imap_resource_0rc"`).
   - Plasma 6 runs `org.freedesktop.secrets` via `ksecretd` backed by `kdewallet`, which `libqt6keychain` accesses directly.
6. **Impermanence:** `/home` persists on `@home`, so Akonadi's DB and synced mail cache survive reboots; on a brand-new install, `kmail-provision` bootstraps everything automatically on first Plasma login.

---

## 4. Approaches Considered

### Approach 1: `agenix` JSON + Idempotent D-Bus / KConfig / QtKeychain Provisioner *(Chosen)*
- **Summary:** Store accounts and app passwords in `secrets/<user>-kmail.json.age`. Run a `systemd --user` oneshot provisioner (`pkgs/kmail-provision`) after Plasma login that creates/updates Akonadi IMAP resources via D-Bus, merges `mailtransports` and `emailidentities`, and stores passwords via a tiny `qt6keychain` helper binary.
- **Trade-offs:** ~200–300 lines of custom Python + ~50 lines of C++ to maintain in `nixcfg`, in exchange for 100% zero-touch declarative KMail with native Kleopatra/GnuPG integration and zero sensitive data in public git.

### Approach 2: Switch to Thunderbird (`programs.thunderbird` + `withExternalGnupg = true`)
- **Summary:** Use Home Manager's built-in Thunderbird module with external GnuPG delegation.
- **Trade-offs:** Less custom code, but Thunderbird still maintains its own internal RNP OpenPGP database for public keys and trust states (drifting from Kleopatra), cannot read `.age` secrets at Nix eval time, and still requires per-host app password entry.

### Approach 3: Switch to `aerc` (TUI client with native `gpgme`)
- **Summary:** Replace KMail with a terminal mail client whose config is trivially templated from `agenix` secrets and talks natively to `~/.gnupg` / `gpg-agent`.
- **Trade-offs:** Simplest declarative setup with strong GnuPG support, but gives up a desktop GUI mail client and KDE/Kontact integration.

- **Why Approach 1 was chosen:** Joel values KMail's unmatched Kleopatra/GnuPG integration in a desktop GUI, uses Gmail with app passwords (removing OAuth2 friction), and wants all account config kept encrypted out of public `nixcfg`.

---

## 5. Architecture & Decided Design

```
  secrets/<user>-kmail.json.age (private nixos-secrets submodule)
               │  agenix decrypt (mode 0400, owner <user>)
               ▼
  /run/agenix/<user>-kmail.json
               │
               ▼  systemd --user: kmail-provision.service (After=graphical-session.target)
  ┌─────────────────────────────────────────────────────────────────────┐
  │  pkgs/kmail-provision/kmail_provision.py                            │
  │                                                                     │
  │  1. Validate JSON & apply provider presets ("gmail" / "custom")     │
  │  2. Wait for Akonadi + Secret Service / KWallet readiness           │
  │  3. Resolve GPG fingerprints (explicit or auto-match via gpg CLI)   │
  │  4. Reconcile SMTP transports  ──► ~/.config/mailtransports         │
  │                                ──► kmail-keychain-set mailtransports│
  │  5. Reconcile identities       ──► ~/.config/emailidentities        │
  │                                ──► ~/.config/emaildefaults          │
  │  6. Reconcile IMAP resources   ──► D-Bus Akonadi /AgentManager      │
  │                                ──► D-Bus /Settings (Imap.Settings)  │
  │                                ──► kmail-keychain-set imap <id>rc   │
  │  7. Persist ID map (no secrets)──► ~/.local/share/kmail-provision/  │
  │                                    state.json (mode 0600)           │
  └─────────────────────────────────────────────────────────────────────┘
```

### 5.1 Encrypted JSON Schema (`secrets/<user>-kmail.json.age`) *(Our Call)*

```json
{
  "version": 1,
  "defaultAccount": "personal",
  "defaultIdentity": "custom-domain",
  "accounts": [
    {
      "id": "personal",
      "name": "Personal Gmail",
      "provider": "gmail",
      "email": "alice@example.com",
      "realName": "Alice Example",
      "password": "abcd efgh ijkl mnop",
      "disableFcc": true,
      "gpg": {
        "key": "auto",
        "signByDefault": false,
        "encryptByDefault": false,
        "autocrypt": false
      },
      "aliases": [
        {
          "id": "custom-domain",
          "name": "Alice (Custom Domain)",
          "email": "alice@custom.example",
          "realName": "Alice Example",
          "gpg": {
            "key": "auto",
            "signByDefault": false,
            "encryptByDefault": false
          }
        }
      ],
      "imap": {
        "intervalCheckMinutes": 5,
        "disconnectedMode": true
      },
      "smtp": {}
    }
  ]
}
```

**Schema rules & defaults *(our call)*:**
- `version`: Must be `1`.
- `defaultAccount`: Optional account `id` (defaults to the first account in `accounts`). Sets `[General] default` transport in `mailtransports` (and defaults `defaultIdentity` when `defaultIdentity` is omitted).
- `defaultIdentity`: Optional `id` of any account **or alias** (defaults to `defaultAccount`). Sets `[General] Default Identity` in `emailidentities` and `[PROFILE_Default]` in `emaildefaults`, allowing a Send-As alias (e.g., a custom domain) to be KMail's default From identity while inheriting the parent Gmail SMTP transport.
- `accounts[].id`: Stable slug (e.g., `"personal"`, `"work"`), unique across accounts and aliases. Used to derive deterministic IDs so renaming `name` or changing `email` updates in place instead of duplicating.
- `accounts[].provider`: `"gmail"` (default) or `"custom"`.
  - When `"gmail"`: defaults `imap` to `{ host: "imap.gmail.com", port: 993, safety: "SSL", auth: "PLAIN", username: email, intervalCheckMinutes: 5, disconnectedMode: true }`, `smtp` to `{ host: "smtp.gmail.com", port: 465, encryption: "SSL", auth: "PLAIN", username: email }`, and `disableFcc` to `true` (because Gmail's SMTP server already saves sent mail into `[Gmail]/Sent Mail`, avoiding duplicate copies in KMail's local `sent-mail` folder). ASCII spaces inside Gmail app passwords are stripped automatically for copy-paste tolerance; `"custom"` passwords are kept verbatim.
  - When `"custom"`: `imap.host` and `smtp.host` are required; sensible TLS defaults (`imap.port = 993`, `imap.safety = "SSL"`, `imap.auth = "PLAIN"`, `smtp.port = 465`, `smtp.encryption = "SSL"`, `smtp.auth = "PLAIN"`, `disableFcc = false`).
- `accounts[].disableFcc` (and optional override on `aliases[].disableFcc`): Boolean written to `Disable Fcc` in `emailidentities`; aliases inherit from their parent account unless explicitly overridden.
- `accounts[].password`: Shared password used for both IMAP and SMTP unless `imap.password` or `smtp.password` overrides it.
- `accounts[].gpg` (and `aliases[].gpg`):
  - Omitted or `{ "key": "auto" }`: runs `gpg --list-secret-keys --with-colons` and binds the primary 40-char fingerprint if **exactly one** valid (non-revoked, non-expired) secret key has a UID matching `email` (case-insensitive). If 0 or >1 match, logs a warning and leaves GPG unbound (does not fail provisioning).
  - Explicit 40-char hex fingerprint string in `gpg.key`: bound unconditionally.
  - `gpg: null` or `gpg.enable: false`: explicitly leaves GPG unbound on that identity.
- `accounts[].aliases`: Optional list of send-as identities. Each creates its own entry in `emailidentities` referencing the parent account's `Transport` ID (unless the alias specifies its own `smtp` block, in which case it also gets its own SMTP transport + keychain entry). KMail's reply logic automatically matches incoming messages addressed to an alias back to that alias's identity and GPG key.

### 5.2 Package: `pkgs/kmail-provision/` *(Our Call)*

Two binaries built in one derivation (`pkgs/kmail-provision/default.nix`):

1. **`kmail-keychain-set`** (C++17, ~55 lines, linked against `pkgs.qt6.qtbase` and `pkgs.qt6Packages.qtkeychain`):
   - CLI: `kmail-keychain-set <service> <key>`
   - Reads the secret from `stdin` (stripping a single trailing newline if present) so passwords never appear in `argv` / `/proc`.
   - First executes `QKeychain::ReadPasswordJob(service)` for `key`: if the stored password already equals the input, exits `0` immediately without dirtying the wallet.
   - Otherwise executes `QKeychain::WritePasswordJob(service)` with `setKey(key)` and `setTextData(password)` and exits `0` on success or non-zero with error message (never printing the password) on failure.
   - Runs under `QCoreApplication` (no X11/Wayland window needed, only `DBUS_SESSION_BUS_ADDRESS`).

2. **`kmail-provision`** (Python 3 stdlib, matching `pkgs/beszel-query/` structure + `pytest` unit tests):
   - CLI flags:
     - `--config <path>` (required, e.g. `/run/agenix/joel-kmail.json`)
     - `--state-file <path>` (default `~/.local/share/kmail-provision/state.json`)
     - `--config-dir <path>` (default `$XDG_CONFIG_HOME` or `~/.config`)
     - `--dry-run` (logs all planned mutations with secrets redacted; performs zero writes/D-Bus mutations)
     - `--prune` (optional: removes previously *managed* resources/transports/identities whose `id` is no longer in the JSON; default off)
     - `--wait-seconds <int>` (default `30`: bounded wait for Akonadi + Secret Service/KWallet readiness on login)
   - **Deterministic ID derivation:**
     - `transport_id = 100_000 + (int(sha256(f"kmail-provision:transport:{slug}").hexdigest()[:8], 16) % 899_999_999)`
     - `identity_uoid = 100_000_000 + (int(sha256(f"kmail-provision:identity:{slug}").hexdigest()[:8], 16) % 2_000_000_000)`
     - Collision-checked across all accounts and aliases before any mutation occurs.
   - **INI / KConfig file editing:**
     - Read/write `~/.config/mailtransports`, `~/.config/emailidentities`, and `~/.config/emaildefaults` with a clean KConfig-compatible INI helper (preserving key case, untouched sections, and `[$e]` / KDE key syntax, writing atomically via temp file + `os.replace` with `0600` permissions) rather than shelling out 50 times to `kwriteconfig6`—making unit testing completely self-contained and atomic.
     - First-run cleanup: if `~/.config/emailidentities` contains only the auto-generated default identity with a blank `Email Address` (like `francis`'s current `[Identity #0]` with `Default Domain=francis`), replace it in-place with the default managed identity so KMail doesn't show a broken nameless identity alongside the real ones.
   - **Akonadi D-Bus interaction:**
     - Uses `qdbus` (`pkgs.qt6.qttools`) behind a thin mockable adapter class (`AkonadiClient`) so unit tests need zero live D-Bus session.
     - If `org.freedesktop.Akonadi.Control` is not on the session bus, invokes `akonadictl start` and polls `/AgentManager` up to `--wait-seconds`.
     - Resource matching order for each account:
       1. `state.json` recorded `resource_id`, verified to still exist in `agentInstances()` with type `akonadi_imap_resource`.
       2. Fallback scan of existing `akonadi_imap_resource_*` instances whose D-Bus `imapServer()` + `userName()` match the account (handles fresh `state.json` loss without creating duplicates!).
       3. Otherwise `createAgentInstance("akonadi_imap_resource")` and poll until `org.freedesktop.Akonadi.Resource.<res_id>` `/Settings` answers on D-Bus.
     - Reads current values from `/Settings` first; only calls setters + `save()` + `restartAgentInstance(res_id)` when at least one setting or keychain password actually changed (true no-op on steady-state logins!).
   - **Keychain interaction:**
     - Behind a mockable `KeychainClient` adapter calling `kmail-keychain-set`.
     - Waits up to `--wait-seconds` for `org.freedesktop.secrets` or `org.kde.kwalletd6` to appear on session D-Bus (returns non-zero if wallet is locked/unavailable so `systemd` logs clearly without corrupting config).
   - **State file (`~/.local/share/kmail-provision/state.json`):**
     - Written with mode `0600`, stores only `{ "version": 1, "managed": { "<id>": { "resource_id": ..., "transport_id": ..., "identity_uoid": ..., "aliases": { "<alias_id>": { "identity_uoid": ..., "transport_id": ... } } } } }`. Zero passwords or personal data beyond opaque IDs.

### 5.3 NixOS Module (`modules/kmail.nix`) & User Wiring *(Our Call)*

- Auto-imported by `modules/default.nix`.
- Options:
  ```nix
  options.kmail = {
    users = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          enable = lib.mkEnableOption "Enable declarative KMail provisioning for this user";
          configFile = lib.mkOption {
            type = with lib.types; nullOr (either path str);
            default = null;
            description = "Path to decrypted kmail JSON config (typically from agenix).";
          };
          prune = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Remove previously managed KMail accounts removed from configFile.";
          };
        };
      });
      default = {};
    };
  };
  ```
- Config (active per user only when `config.plasma.enable && cfg.enable && cfg.configFile != null`):
  - Adds `kmail-provision` to `home-manager.users.${user}.home.packages` so the user can run `kmail-provision --dry-run` or re-run manually anytime.
  - Defines `home-manager.users.${user}.systemd.user.services.kmail-provision`:
    - `Unit`: `Description = "Provision declarative KMail accounts"`, `After = ["graphical-session.target" "plasma-kwallet-pam.service"]`, `PartOf = ["graphical-session.target"]`, `ConditionPathExists = toString cfg.configFile`, `StartLimitBurst = 10`, `StartLimitIntervalSec = "10min"`
    - `Service`: `Type = "oneshot"`, `Restart = "no"`, `RestartForceExitStatus = [2]`, `RestartSec = "30s"`, `ExecStart = "${kmailProvision}/bin/kmail-provision --config ${cfg.configFile}${lib.optionalString cfg.prune " --prune"}"` (omits `RemainAfterExit=true` so `systemd.user.paths` re-triggers on secret updates)
    - `Install`: `WantedBy = ["graphical-session.target"]`
  - Defines `home-manager.users.${user}.systemd.user.paths.kmail-provision` watching `PathChanged = toString cfg.configFile` (`WantedBy = ["graphical-session.target"]`) so updating the agenix secret and running `nixos-rebuild switch` automatically re-runs provisioning without needing to log out and back in!
- Wiring in `users/joel.nix`:
  - Guarded secret definition matching existing repo pattern:
    ```nix
    kmailSecretFile = lib.custom.relativeToRoot "secrets/${username}-kmail.json.age";
    hasKmailSecret = builtins.pathExists kmailSecretFile;
    ```
  - When `hasKmailSecret`: defines `age.secrets."${username}-kmail-json"` (`mode = "0400"`, `owner = username`, `group = "users"`) and enables `kmail.users.${username}` when `config.${username}.desktop`.

### 5.4 Testing & Documentation *(Our Call)*
- **Unit tests (`pkgs/kmail-provision/test_kmail_provision.py`):**
  - Run in `pytest` during `nix build` (`doCheck = true`) AND runnable standalone via `pytest` in devShell.
  - Cover: Gmail preset expansion, custom provider validation, alias inheritance & override, GPG `"auto"` matching (unique match, 0 matches, ambiguous >1 matches, revoked/expired key ignored, explicit fingerprint override), deterministic ID stability & collision check, KConfig INI merge preserving unmanaged sections + replacing blank default identity, Akonadi D-Bus creation vs in-place update vs steady-state no-op, fallback resource matching when `state.json` is missing, `--dry-run` side-effect freedom & password redaction, and `--prune` removing only managed items while keeping unmanaged items intact.
- **Howto doc (`docs/howto/declarative-kmail.md`):**
  - Step-by-step instructions to create `secrets/joel-kmail.json.age`, register its rule in `secrets/agenix-rules.nix` (`publicKeys = [keys.hosts.francis keys.hosts.agnes keys.hosts.jerome keys.joel]`), rebuild, test with `--dry-run`, and verify in KMail + Kleopatra.

---

## 6. Open Calls Left to the Builder
- Exact CMake/pkg-config build invocation in `pkgs/kmail-provision/default.nix` for compiling `kmail-keychain-set` against `qt6.qtbase` + `qt6Packages.qtkeychain`.
- Exact `kmail-provision` logging format and exit codes (e.g., distinct exit code for "wallet locked / session not ready" vs "invalid JSON schema").
- Whether to also emit `org.kde.pim.TransportManager` / `org.kde.pim.IdentityManager` D-Bus reload notifications if KMail is already open during a live re-provision.
