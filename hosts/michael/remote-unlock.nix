# Copyright (c) Joel Benway
# SPDX-License-Identifier: MIT
{
  config,
  lib,
  pkgs,
  ...
}: let
  ports = import (lib.custom.relativeToRoot "data/ports.nix");
  initrdPort = toString ports.initrdSsh.ssh;

  zitaUnlockPkg = pkgs.writeShellApplication {
    name = "zita-unlock";
    runtimeInputs = with pkgs; [openssh netcat];
    text = ''
      target="''${1:-zita.home}"
      port="''${2:-${initrdPort}}"
      keyfile="${config.age.secrets.zita-luks-passphrase.path}"

      if [ ! -r "$keyfile" ]; then
        echo "Error: Passphrase file $keyfile is not readable." >&2
        exit 1
      fi

      echo "Attempting to unlock Zita initrd ($target:$port)..."
      ssh -o StrictHostKeyChecking=accept-new \
          -o UserKnownHostsFile=/dev/null \
          -o LogLevel=ERROR \
          -o ConnectTimeout=5 \
          -i /etc/ssh/ssh_host_ed25519_key \
          -p "$port" \
          root@"$target" \
          "systemd-tty-ask-password-agent" < "$keyfile"
      echo "Passphrase successfully transmitted to Zita."
    '';
  };
in {
  age.secrets.zita-luks-passphrase = {
    file = lib.custom.relativeToRoot "secrets/zita-luks-passphrase.age";
    name = "zita-luks-passphrase.txt";
    mode = "400";
    owner = "root";
    group = "root";
  };

  environment.systemPackages = [zitaUnlockPkg];

  systemd.services.zita-auto-unlock = {
    description = "Probe and auto-unlock Zita initrd LUKS";
    path = with pkgs; [netcat];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "zita-auto-unlock-probe" ''
        KEYFILE="${config.age.secrets.zita-luks-passphrase.path}"
        if [ ! -r "$KEYFILE" ]; then
          exit 0
        fi

        for target in "zita.home" "192.168.77.20"; do
          if nc -z -w 2 "$target" ${initrdPort} 2>/dev/null; then
            echo "Detected Zita initrd SSH at $target:${initrdPort}. Transmitting LUKS passphrase..."
            ${zitaUnlockPkg}/bin/zita-unlock "$target" ${initrdPort} || true
            break
          fi
        done
      '';
    };
  };

  systemd.timers.zita-auto-unlock = {
    description = "Periodic probe to auto-unlock Zita initrd";
    wantedBy = ["timers.target"];
    timerConfig = {
      OnBootSec = "1m";
      OnUnitActiveSec = "15s";
    };
  };
}
