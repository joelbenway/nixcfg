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
        environmentFile = cfgServer.environmentFile;
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

      systemd.services.ntfy-sh = {
        after = lib.optionals (config.impermanence.enable or false) [dataDirMountUnit];
        wants = lib.optionals (config.impermanence.enable or false) [dataDirMountUnit];
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
