# Copyright (c) Joel Benway
# SPDX-License-Identifier: MIT
{
  config,
  inputs,
  lib,
  ...
}: let
  cfg = config.secureboot;
in {
  options.secureboot = {
    enable = lib.mkEnableOption "Secure Boot via lanzaboote";
  };

  imports = [inputs.lanzaboote.nixosModules.lanzaboote];

  config = lib.mkIf cfg.enable {
    nixpkgs.overlays = [
      (_final: prev: {
        sbctl = prev.symlinkJoin {
          name = "sbctl-safe-${prev.sbctl.version}";
          paths = [prev.sbctl];
          postBuild = ''
                        rm $out/bin/sbctl
                        cat <<'EOF' > $out/bin/sbctl
            #!${prev.bash}/bin/bash
            set -euo pipefail

            # Guard against signing files in /boot/EFI/nixos/ (e.g. kernel-*.efi)
            for arg in "$@"; do
              if [[ "$arg" =~ /EFI/nixos/ ]] || [[ "$arg" =~ kernel-.*\.efi$ ]]; then
                echo "ERROR: Refusing to sign or touch files in /boot/EFI/nixos/!" >&2
                echo "Lanzaboote uses thin stubs (/boot/EFI/Linux/*.efi) that verify raw kernels via SHA-256." >&2
                echo "Signing /boot/EFI/nixos/kernel-*.efi modifies the binary in-place, which corrupts the SHA-256 hash and causes unbootable panics!" >&2
                exit 1
              fi
            done

            # Guard against sbctl sign-all if /var/lib/sbctl/files.json contains /EFI/nixos/ entries
            if [[ "$*" =~ sign-all ]]; then
              if [ -f /var/lib/sbctl/files.json ] && grep -q "/EFI/nixos/" /var/lib/sbctl/files.json 2>/dev/null; then
                echo "ERROR: /var/lib/sbctl/files.json contains files in /boot/EFI/nixos/!" >&2
                echo "Refusing to run 'sbctl sign-all' because signing raw kernels will break Lanzaboote boot." >&2
                echo "Run 'sbctl remove-file <path>' to remove them from the database first." >&2
                exit 1
              fi
            fi

            # If interactive verify (not --json), print a helpful note clarifying Lanzaboote raw kernels
            if [[ "$*" =~ verify ]] && ! [[ "$*" =~ --json ]]; then
              "${prev.sbctl}/bin/sbctl" "$@"
              ret=$?
              echo ""
              echo "Note: Files in /boot/EFI/nixos/ (kernel-*.efi) are Lanzaboote raw kernels verified via"
              echo "SHA-256 hashes by /boot/EFI/Linux/*.efi thin stubs. They are intentionally NOT Authenticode-signed."
              exit $ret
            fi

            exec "${prev.sbctl}/bin/sbctl" "$@"
            EOF
                        chmod +x $out/bin/sbctl
          '';
        };
      })
    ];

    boot = {
      lanzaboote = {
        enable = true;
        pkiBundle = "/var/lib/sbctl";
        autoGenerateKeys.enable = true;
        autoEnrollKeys = {
          enable = true;
          autoReboot = true;
        };
      };
      loader = {
        systemd-boot.enable = lib.mkForce false;
        efi.canTouchEfiVariables = true;
      };
    };
  };
}
