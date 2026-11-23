---
type: howto
title: "How-To: Declarative KMail Account Provisioning"
description: "Setup and verification guide for agenix-encrypted declarative KMail accounts, Gmail Send-As aliases, Kleopatra GPG bindings, and QtKeychain credentials."
status: active
trust: verified
owner: joel
timestamp: "2026-11-23"
tags:
  - howto
  - kmail
  - kde
  - agenix
  - gpg
---

# How to Configure Declarative KMail Provisioning

`modules/kmail.nix` + `pkgs/kmail-provision` declaratively provisions KMail incoming IMAP accounts, outgoing SMTP transports, Send-As aliases, Kleopatra/GnuPG key bindings, and QtKeychain passwords from an `agenix`-encrypted JSON file—keeping all email addresses and app passwords out of the public `nixcfg` repository.

---

## 1. Register the Secret Rule

Add the secret entry to `secrets/agenix-rules.nix` (restricting decryption to desktop workstations and your admin key):

```nix
"joel-kmail.json.age".publicKeys = [
  keys.hosts.francis
  keys.hosts.agnes
  keys.hosts.jerome
  keys.joel
];
```

---

## 2. Create and Encrypt `secrets/joel-kmail.json.age`

Create a Gmail App Password (Google Account → Security → 2-Step Verification → App passwords), then encrypt your JSON config from inside `secrets/`:

```bash
cd secrets
agenix -e joel-kmail.json.age
```

Example JSON payload (using placeholder values—replace with your real addresses and Gmail App Password):

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
      "email": "alice@gmail.example",
      "realName": "Alice Example",
      "password": "xxxx xxxx xxxx xxxx",
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
        },
        {
          "id": "duck-alias",
          "name": "Alice (Duck)",
          "email": "alias@duck.example",
          "realName": "Alias Name",
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
      }
    }
  ]
}
```

### Schema Highlights
- **`provider: "gmail"`** automatically fills `imap.gmail.com:993` (`SSL`, `PLAIN`), `smtp.gmail.com:465` (`SSL`, `PLAIN`), `disableFcc: true` (so Gmail's server-side `[Gmail]/Sent Mail` copy isn't duplicated locally), and strips spaces from Gmail App Passwords. Use `"provider": "custom"` for any standard IMAP/SMTP server.
- **`defaultIdentity`** can point to any account **or alias** `id` so your preferred Send-As address is KMail's default `From:` identity.
- **`gpg.key: "auto"`** matches a unique valid secret key by email UID from `~/.gnupg` (already imported by `modules/gpg.nix`). You can also set an explicit 40-char fingerprint or `"gpg": null` to disable GPG binding on an identity.
- **Safety:** Manually added KMail accounts/identities/transports are never overwritten or removed. Pruning removed managed entries is disabled by default (`kmail.users.<user>.prune = false`).

Commit and push the `secrets` submodule, then bump the submodule pointer in `nixcfg`.

---

## 3. Rebuild & Verify

1. **Rebuild the host** so `users/joel.nix` detects `secrets/joel-kmail.json.age` and enables `kmail.users.joel`:
   ```bash
   sudo nixos-rebuild switch --flake .#$(hostname)
   ```

2. **Preview without modifying anything (`--dry-run` redacts all passwords):**
   ```bash
   kmail-provision --config /run/agenix/joel-kmail.json --dry-run
   ```

3. **Run or inspect the user service:**
   ```bash
   systemctl --user start kmail-provision.service
   journalctl --user -u kmail-provision.service -n 50 --no-pager
   ```

4. **Confirm in KMail:**
   - Open **KMail → Settings → Configure KMail → Accounts**: verify the IMAP receiving account and SMTP sending transport exist and connect without password prompts.
   - Open **Identities**: verify each identity (and Send-As alias) shows the expected `Email Address`, outgoing `Transport`, and bound **Cryptography** OpenPGP signing/encryption key from Kleopatra.
   - Re-run `systemctl --user start kmail-provision.service` and confirm logs report `KMail configuration already up to date` (strict idempotent no-op).
