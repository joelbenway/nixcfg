# Copyright (c) Joel Benway
# SPDX-License-Identifier: MIT
let
  ports = {
    # Web & Application Services
    copyparty = {
      internal = 3920;
      tailscale = 3923;
    };
    actual = {
      internal = 5005;
      tailscale = 5006;
    };
    plaid = {
      internal = 8084;
      tailscale = 8086;
    };
    jellyfin = {
      internal = 8096;
      tailscale = 8097;
    };
    forgejo = {
      internal = 3001;
      tailscale = 3002;
      ssh = 2220;
    };

    # Fleet & Infrastructure Services
    binaryCache = {
      internal = 5000;
    };
    telemetry = {
      internal = 3000;
    };
    autoUpdate = {
      internal = 9105;
    };
    hnsd = {
      resolver = 5350;
      root = 5354;
    };
    syncthing = {
      sync = 22000;
    };

    # System & Remote Management
    initrdSsh = {
      ssh = 2222;
    };
  };

  # Flatten attributes to collect all assigned ports
  collectPorts = attrs:
    builtins.concatLists (
      builtins.map (
        val:
          if builtins.isInt val
          then [val]
          else if builtins.isAttrs val
          then collectPorts val
          else []
      ) (builtins.attrValues attrs)
    );

  allPorts = collectPorts ports;

  # Check for duplicate port numbers
  findDuplicates = list: let
    counts = builtins.foldl' (acc: x:
      acc // {"${toString x}" = (acc."${toString x}" or 0) + 1;}) {}
    list;
  in
    builtins.filter (x: counts."${toString x}" > 1) (builtins.attrNames counts);

  duplicates = findDuplicates allPorts;
in
  if duplicates != []
  then throw "Port collision detected in data/ports.nix: duplicate ports [ ${builtins.concatStringsSep ", " duplicates} ]"
  else ports
