# Copyright (c) Joel Benway
# SPDX-License-Identifier: MIT
{
  config,
  lib,
  pkgs,
  ...
}: {
  options.tpm = {
    enable = lib.mkEnableOption "Enable TPM2-based LUKS disk enrollment.";
    passwordFile = lib.mkOption {
      type = with lib.types; nullOr (either path str);
      default = null;
      example = "/run/secrets/luks-password";
      description = ''
        Path to a file containing the passphrase to unlock the LUKS volume.
        Trailing newlines are stripped before passing to systemd-cryptenroll --unlock-key-file.
      '';
    };
    devices = lib.mkOption {
      type = with lib.types; listOf path;
      default = [];
      example = ["/dev/nvme0n1p2" "/dev/sda2"];
      description = ''
        List of LUKS-encrypted block devices to enroll with TPM2.
      '';
    };
    pcrs = lib.mkOption {
      type = lib.types.str;
      default = "0+7";
      example = "0+7";
      description = ''
        PCR values to bind the TPM enrollment to.
        Default includes firmware (0) and secure boot policy (7).
        Binding to PCR 12 or 2 is avoided by default on NixOS because PCR 12
        measures the kernel command line (which changes with every NixOS system
        generation store path), and PCR 2 measures Option ROMs / PCIe cards.
      '';
    };
  };

  config = lib.mkIf config.tpm.enable {
    assertions = [
      {
        assertion = config.tpm.devices != [];
        message = "tpm.devices must be set when tpm.enable is true";
      }
      {
        assertion = config.tpm.passwordFile != null;
        message = "tpm.passwordFile must be set when tpm.enable is true";
      }
    ];

    systemd.services.tpm-enroll = {
      description = "Enroll LUKS devices in tpm2";
      wantedBy = ["multi-user.target"];
      after = ["tpm2.target" "agenix.service"];
      wants = ["tpm2.target" "agenix.service"];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      path = [
        pkgs.coreutils
        pkgs.systemd
        pkgs.util-linux
      ];
      enableStrictShellChecks = true;
      script =
        # bash
        ''
          CLEAN_PASSPHRASE=$(mktemp)
          trap 'rm -f "$CLEAN_PASSPHRASE"' EXIT
          tr -d '\n' < "${config.tpm.passwordFile}" > "$CLEAN_PASSPHRASE"
          ${lib.concatMapStringsSep "\n" (device: ''
              echo "Checking ${device} (target PCRs: ${config.tpm.pcrs})..."
              if [ -e "${device}" ]; then
                systemd-cryptenroll \
                  --unlock-key-file="$CLEAN_PASSPHRASE" \
                  --tpm2-device=auto \
                  --tpm2-pcrs=${config.tpm.pcrs} \
                  --wipe-slot=tpm2 \
                  ${device}
              else
                echo "Warning: Device ${device} not found, skipping."
              fi
            '')
            config.tpm.devices}
        '';
    };
  };
}
