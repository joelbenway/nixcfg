# Copyright (c) Joel Benway
# SPDX-License-Identifier: MIT
{
  config,
  hostname,
  lib,
  pkgs,
  utils,
  ...
}: let
  ports = import (lib.custom.relativeToRoot "data/ports.nix");
  tailnet = config.tailscale.tailnet or "gentoo-humboldt.ts.net";
  cfgServer = config.notify.server;
  cfgClient = config.notify.client;

  fleetNotifyPkg = import (lib.custom.relativeToRoot "pkgs/fleet-notify") {inherit pkgs;};
  dataDirMountUnit = "${utils.escapeSystemdPath cfgServer.dataDir}.mount";
  useAdminPasswordFile = cfgServer.admin.passwordFile != null;
  runtimeEnvDir = "/run/ntfy-sh";
  runtimeEnvPath = "${runtimeEnvDir}/env";

  renderNtfyEnvScript = pkgs.writeScriptBin "ntfy-sh-render-env" ''
    #!${pkgs.python3.withPackages (ps: [ps.bcrypt])}/bin/python3
    import grp
    import os
    import pwd
    import sys
    import tempfile
    from pathlib import Path
    import bcrypt

    admin_user = ${builtins.toJSON cfgServer.admin.username}
    pw_path = Path(${builtins.toJSON (toString cfgServer.admin.passwordFile)})
    base_env_path = ${
      if cfgServer.environmentFile != null
      then "Path(${builtins.toJSON (toString cfgServer.environmentFile)})"
      else "None"
    }
    out_dir = Path(${builtins.toJSON runtimeEnvDir})
    out_path = Path(${builtins.toJSON runtimeEnvPath})

    pw = pw_path.read_text(encoding="utf-8").strip()
    if not pw or "\n" in pw or "\r" in pw:
        print("ntfy-sh-render-env: admin password file must contain a single non-empty line", file=sys.stderr)
        sys.exit(1)

    pw_hash = bcrypt.hashpw(
        pw.encode("utf-8"),
        bcrypt.gensalt(rounds=10, prefix=b"2a"),
    ).decode("ascii")
    admin_entry = f"{admin_user}:{pw_hash}:admin"

    lines = []
    if base_env_path is not None and base_env_path.exists():
        lines = base_env_path.read_text(encoding="utf-8").splitlines()

    updated_lines = []
    found_users = False
    for line in lines:
        if line.startswith("NTFY_AUTH_USERS="):
            found_users = True
            raw_val = line.split("=", 1)[1]
            entries = [e for e in raw_val.split(",") if e.strip()]
            filtered = [e for e in entries if e.split(":", 1)[0] != admin_user]
            updated_lines.append("NTFY_AUTH_USERS=" + ",".join([admin_entry] + filtered))
        else:
            updated_lines.append(line)

    if not found_users:
        updated_lines.append(f"NTFY_AUTH_USERS={admin_entry}")

    uid = pwd.getpwnam("ntfy-sh").pw_uid
    gid = grp.getgrnam("ntfy-sh").gr_gid
    out_dir.mkdir(parents=True, exist_ok=True)
    os.chmod(out_dir, 0o750)
    os.chown(out_dir, 0, gid)

    fd, tmp_name = tempfile.mkstemp(prefix=".env.", dir=str(out_dir))
    try:
        os.fchmod(fd, 0o400)
        os.fchown(fd, uid, gid)
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write("\n".join(updated_lines) + "\n")
        os.replace(tmp_name, out_path)
    except BaseException:
        try:
            os.unlink(tmp_name)
        except OSError:
            pass
        raise
  '';

  clientConfigJson = builtins.toJSON {
    host = hostname;
    urls = cfgClient.urls;
    defaultTopic = cfgClient.defaultTopic;
    desktopTopics = cfgClient.desktopTopics;
    publishTokenFile =
      if cfgClient.publishTokenFile != null
      then toString cfgClient.publishTokenFile
      else null;
    subscribeTokenFile =
      if cfgClient.subscribeTokenFile != null
      then toString cfgClient.subscribeTokenFile
      else null;
  };
in {
  options.notify = {
    server = {
      enable = lib.mkEnableOption "Self-hosted ntfy-sh fleet notification bus server";

      domain = lib.mkOption {
        type = lib.types.str;
        default = "notify.benway.me";
        description = "Domain name under which ntfy-sh is exposed via reverse proxy.";
      };

      port = lib.mkOption {
        type = lib.types.port;
        default = ports.ntfy.internal;
        description = "Internal loopback HTTP port for ntfy-sh.";
      };

      tailscalePort = lib.mkOption {
        type = lib.types.port;
        default = ports.ntfy.tailscale;
        description = "Tailscale HTTPS reverse-proxy port for ntfy-sh.";
      };

      dataDir = lib.mkOption {
        type = lib.types.str;
        default = "/var/lib/ntfy-sh";
        description = "Persistent directory for ntfy-sh user database, message cache, and attachments.";
      };

      environmentFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "Path to agenix env file with NTFY_AUTH_USERS and NTFY_AUTH_TOKENS.";
      };

      admin = {
        username = lib.mkOption {
          type = lib.types.str;
          default = "joel";
          description = "Administrator username whose password is synced from admin.passwordFile.";
        };

        passwordFile = lib.mkOption {
          type = with lib.types; nullOr (either path str);
          default = null;
          description = "Optional plaintext password file (e.g. agenix joel-passphrase) bcrypt-hashed into volatile /run/ntfy-sh/env before ntfy-sh starts.";
        };
      };

      cacheDuration = lib.mkOption {
        type = lib.types.str;
        default = "72h";
        description = "How long ntfy-sh retains cached messages for offline/sleeping clients.";
      };

      extraAccess = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        description = "Additional ntfy auth-access ACL entries appended to the fleet defaults.";
      };

      extraSettings = lib.mkOption {
        type = lib.types.attrsOf lib.types.anything;
        default = {};
        description = "Extra ntfy server.yml settings merged into services.ntfy-sh.settings.";
      };
    };

    client = {
      enable = lib.mkEnableOption "Fleet notification bus client CLI and systemd OnFailure template";

      urls = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [
          "https://notify.benway.me"
          "https://zita.${tailnet}:${toString ports.ntfy.tailscale}"
        ];
        description = "Ordered list of ntfy base URLs tried by fleet-notify and desktop subscribers.";
      };

      publishTokenFile = lib.mkOption {
        type = with lib.types; nullOr (either path str);
        default = null;
        description = "Path to file containing write-only fleet-pub ntfy bearer token.";
      };

      subscribeTokenFile = lib.mkOption {
        type = with lib.types; nullOr (either path str);
        default = null;
        description = "Path to file containing read-only fleet-sub ntfy bearer token (for desktop consumers).";
      };

      defaultTopic = lib.mkOption {
        type = lib.types.str;
        default = "fleet-alerts";
        description = "Default ntfy topic when fleet-notify is invoked without --topic.";
      };

      desktopTopics = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = ["fleet-alerts" "fleet-updates"];
        description = "Topics streamed by desktop notification subscribers.";
      };

      onFailureUnits = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        description = "Systemd service names (without .service) wired to fleet-notify@%n.service via OnFailure=.";
      };

      package = lib.mkOption {
        type = lib.types.package;
        default = fleetNotifyPkg;
        readOnly = true;
        description = "The fleet-notify package exposing fleet-notify and fleet-notify-desktop binaries.";
      };
    };
  };

  config = lib.mkMerge [
    (lib.mkIf cfgServer.enable {
      users.users.ntfy-sh = {
        isSystemUser = true;
        group = "ntfy-sh";
        home = cfgServer.dataDir;
        description = "ntfy-sh fleet notification server user";
      };

      users.groups.ntfy-sh = {};

      services.ntfy-sh = {
        enable = true;
        environmentFile =
          if useAdminPasswordFile
          then runtimeEnvPath
          else cfgServer.environmentFile;
        settings =
          {
            base-url = "https://${cfgServer.domain}";
            listen-http = "127.0.0.1:${toString cfgServer.port}";
            behind-proxy = true;
            auth-default-access = "deny-all";
            auth-file = "${cfgServer.dataDir}/user.db";
            cache-file = "${cfgServer.dataDir}/cache.db";
            cache-duration = cfgServer.cacheDuration;
            attachment-cache-dir = "${cfgServer.dataDir}/attachments";
            enable-signup = false;
            enable-login = true;
            enable-metrics = false;
            keepalive-interval = "45s";
          }
          // lib.optionalAttrs (cfgServer.environmentFile != null) {
            # Admin users (joel) have global rw implicitly; ntfy rejects ACL rules on admin users.
            auth-access =
              [
                "fleet-pub:fleet-*:wo"
                "fleet-sub:fleet-*:ro"
              ]
              ++ cfgServer.extraAccess;
          }
          // cfgServer.extraSettings;
      };

      systemd.services.ntfy-sh-env = lib.mkIf useAdminPasswordFile {
        description = "Render runtime ntfy-sh environment with bcrypt-hashed admin password";
        after = ["agenix.service"];
        wants = ["agenix.service"];
        serviceConfig = {
          Type = "oneshot";
          User = "root";
          Group = "root";
          ExecStart = "${renderNtfyEnvScript}/bin/ntfy-sh-render-env";
        };
      };

      systemd.services.ntfy-sh = {
        after =
          lib.optionals (config.impermanence.enable or false) [dataDirMountUnit]
          ++ lib.optional useAdminPasswordFile "ntfy-sh-env.service";
        wants = lib.optionals (config.impermanence.enable or false) [dataDirMountUnit];
        requires = lib.optional useAdminPasswordFile "ntfy-sh-env.service";
        serviceConfig = {
          DynamicUser = lib.mkForce false;
          PrivateUsers = lib.mkForce false;
          User = "ntfy-sh";
          Group = "ntfy-sh";
        };
      };

      systemd.tmpfiles.rules = [
        "d ${cfgServer.dataDir} 0750 ntfy-sh ntfy-sh -"
        "d ${cfgServer.dataDir}/attachments 0750 ntfy-sh ntfy-sh -"
      ];

      impermanence.directories = lib.mkIf (config.impermanence.enable or false) [
        cfgServer.dataDir
      ];
    })

    (lib.mkIf cfgClient.enable {
      environment = {
        systemPackages = [fleetNotifyPkg];
        etc."fleet-notify/config.json" = {
          text = clientConfigJson;
          mode = "0644";
        };
      };

      systemd.services =
        {
          "fleet-notify@" = {
            description = "Publish systemd unit failure notification for %i";
            after = ["network-online.target"];
            wants = ["network-online.target"];
            serviceConfig = {
              Type = "oneshot";
              ExecStart = "${fleetNotifyPkg}/bin/fleet-notify --best-effort --unit %i";
            };
          };
        }
        // lib.genAttrs cfgClient.onFailureUnits (_: {
          unitConfig.OnFailure = lib.mkAfter ["fleet-notify@%n.service"];
        });
    })
  ];
}
