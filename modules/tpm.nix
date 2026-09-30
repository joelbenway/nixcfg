{
  config,
  lib,
  pkgs,
  ...
}: {
  options.tpm = {
    enable = lib.mkEnableOption "Enable TPM2-based LUKS disk enrollment.";
    passwordFile = lib.mkOption {
      type = with lib.types; nullOr path;
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
      default = "0+2+7+12";
      example = "0+2+7+12";
      description = ''
        PCR values to bind the TPM enrollment to.
        Default includes firmware (0), configuration (2), secure boot (7), and kernel config (12).
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
      after = ["tpm2.target"];
      wants = ["tpm2.target"];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      path = [
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
              echo "Checking ${device}..."
              if ! systemd-cryptenroll ${device} | grep -q "tpm2"; then
                echo "Enrolling ${device} with TPM2..."
                systemd-cryptenroll \
                  --unlock-key-file="$CLEAN_PASSPHRASE" \
                  --tpm2-device=auto \
                  --tpm2-pcrs=${config.tpm.pcrs} \
                  --wipe-slot=tpm2 \
                  ${device}
                echo "${device} enrolled successfully"
              else
                echo "${device} already enrolled with TPM2"
              fi
            '')
            config.tpm.devices}
        '';
    };
  };
}
