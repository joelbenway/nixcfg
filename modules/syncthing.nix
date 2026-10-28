# Copyright (c) Joel Benway
# SPDX-License-Identifier: MIT
{
  config,
  hostname,
  lib,
  ...
}: let
  cfg = config.syncthing;
  topology = (import (lib.custom.relativeToRoot "data/syncthing.nix")) {
    inherit (config.tailscale) tailnet;
  };

  certPath = lib.custom.relativeToRoot "data/syncthing/certs/${hostname}.cert.pem";
  keySecretPath = lib.custom.relativeToRoot "secrets/${hostname}-syncthing-key.age";
  hasCert = builtins.pathExists certPath;
  hasKey = builtins.pathExists keySecretPath;

  expandPath = p:
    if lib.hasPrefix "~/" p
    then "/home/${cfg.user}/${lib.removePrefix "~/" p}"
    else p;

  # Filter folders participating in THIS host
  relevantFolders =
    lib.filterAttrs (
      _name: folder: builtins.elem hostname folder.devices
    )
    topology.folders;

  # Find all unique peer hosts that share at least one folder with THIS host
  activePeers = lib.unique (
    lib.flatten (
      lib.mapAttrsToList (
        _name: folder: lib.filter (d: d != hostname) folder.devices
      )
      relevantFolders
    )
  );

  # Derive peer device configs for services.syncthing.settings.devices
  derivedDevices = lib.genAttrs activePeers (peer: {
    inherit (topology.devices.${peer}) id addresses;
  });

  # Derive folder configs for services.syncthing.settings.folders
  derivedFolders =
    lib.mapAttrs (
      _name: folder: {
        inherit (folder) id;
        label = folder.label or folder.id;
        path = expandPath (folder.hostPaths.${hostname} or folder.defaultPath);
        devices = lib.filter (d: d != hostname) folder.devices;
        versioning = folder.versioning or null;
      }
    )
    relevantFolders;
in {
  options.syncthing = {
    enable = lib.mkEnableOption "Declarative Syncthing mesh over Tailscale";

    user = lib.mkOption {
      type = lib.types.str;
      default = "joel";
      description = "User to run the Syncthing system service as";
    };

    guiAddress = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1:8384";
      description = "Listen address for Syncthing Web GUI";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = builtins.hasAttr hostname topology.devices;
        message = "syncthing: host '${hostname}' is not declared in data/syncthing.nix";
      }
      {
        assertion = hasCert;
        message = "syncthing: cert not found at ${toString certPath}";
      }
      {
        assertion = hasKey;
        message = "syncthing: private key secret not found at ${toString keySecretPath}";
      }
    ];

    # Restrict traffic strictly to Tailscale wireguard interface
    networking.firewall.interfaces."tailscale0" = {
      allowedTCPPorts = [22000];
      allowedUDPPorts = [22000];
    };

    # System service
    services.syncthing = {
      enable = true;
      user = cfg.user;
      group = "users";
      dataDir = "/var/lib/syncthing";
      configDir = "/var/lib/syncthing/.config/syncthing";

      # TLS cert (public) & key (agenix secret)
      cert = toString certPath;
      key = config.age.secrets.syncthing-key.path;

      # Purge any unmanaged devices/folders
      overrideDevices = true;
      overrideFolders = true;

      settings = {
        gui = {
          address = cfg.guiAddress;
        };
        options = {
          globalAnnounceEnabled = false;
          localAnnounceEnabled = false;
          relaysEnabled = false;
          urAccepted = -1;
        };
        devices = derivedDevices;
        folders = derivedFolders;
      };
    };

    # Register host-specific private key secret with agenix
    age.secrets.syncthing-key = {
      file = keySecretPath;
      mode = "400";
      owner = cfg.user;
      group = "users";
    };

    # Persist syncthing state across Btrfs rollbacks
    impermanence.directories = lib.optionals config.impermanence.enable [
      "/var/lib/syncthing"
    ];
  };
}
