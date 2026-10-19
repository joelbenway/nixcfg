# Copyright (c) Joel Benway
# SPDX-License-Identifier: MIT
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.tpm;

  tpmScript = pkgs.writeShellApplication {
    name = "tpm-reenroll";
    runtimeInputs = with pkgs; [
      coreutils
      cryptsetup
      gnused
      jq
      systemd
      util-linux
    ];
    text = ''
            devices=(${lib.escapeShellArgs cfg.devices})
            target_pcrs="${cfg.pcrs}"
            password_file="${
        if cfg.passwordFile != null
        then toString cfg.passwordFile
        else ""
      }"

            usage() {
              cat <<EOF
      Usage: tpm-reenroll [OPTIONS]

      Manage TPM2-based LUKS disk unlocking.

      Options:
        --status       Show current keyslots, TPM tokens, and system PCR measurements
        --force        Force re-enrollment even if target PCRs are already enrolled
        -h, --help     Show this help message
      EOF
            }

            show_status() {
              echo "=========================================================="
              echo "TPM LUKS Status (Target PCRs: $target_pcrs)"
              echo "=========================================================="
              for dev in "''${devices[@]}"; do
                echo "Device: $dev"
                if [ ! -e "$dev" ]; then
                  echo "  Status: Device node not found!"
                  continue
                fi
                real_dev=$(readlink -f "$dev")
                echo "  Block device: $real_dev"
                echo "  Keyslots:"
                systemd-cryptenroll "$dev" 2>&1 | sed 's/^/    /' || true
                echo "  TPM2 Tokens:"
                if meta=$(cryptsetup luksDump --dump-json-metadata "$dev" 2>/dev/null); then
                  token_ids=$(echo "$meta" | jq -r '.tokens | to_entries[]? | select(.value.type == "systemd-tpm2") | .key' 2>/dev/null || true)
                  if [ -n "$token_ids" ]; then
                    for tid in $token_ids; do
                      keyslot=$(echo "$meta" | jq -r ".tokens[\"$tid\"].keyslots[0]")
                      pcrs=$(echo "$meta" | jq -c ".tokens[\"$tid\"][\"tpm2-pcrs\"]")
                      echo "    - Token ID: $tid -> Keyslot: $keyslot | Enrolled PCRs: $pcrs"
                    done
                  else
                    echo "    - No TPM2 tokens found."
                  fi
                else
                  echo "    - Unable to read LUKS JSON metadata."
                fi
                echo ""
              done
              echo "Current System PCR Measurements:"
              systemd-analyze pcrs 2>/dev/null | grep -E '^ *(0|2|7|12) ' || true
              echo "=========================================================="
            }

            force_mode=false
            status_mode=false

            while [ "$#" -gt 0 ]; do
              case "$1" in
                --status)
                  status_mode=true
                  shift
                  ;;
                --force)
                  force_mode=true
                  shift
                  ;;
                -h|--help)
                  usage
                  exit 0
                  ;;
                *)
                  echo "Unknown option: $1" >&2
                  usage >&2
                  exit 1
                  ;;
              esac
            done

            if [ "$(id -u)" -ne 0 ]; then
              echo "Error: tpm-reenroll requires root privileges. Please run with sudo." >&2
              exit 1
            fi

            if [ "$status_mode" = true ]; then
              show_status
              exit 0
            fi

            pass_file=$(mktemp)
            trap 'rm -f "$pass_file"' EXIT

            if [ -n "$password_file" ] && [ -r "$password_file" ]; then
              echo "Using configured password file ($password_file)..."
              tr -d '\n' < "$password_file" > "$pass_file"
            else
              if [ -n "$password_file" ]; then
                echo "Configured password file ($password_file) is not readable."
              fi
              echo -n "Enter LUKS passphrase: "
              read -r -s entered_pass
              echo ""
              if [ -z "$entered_pass" ]; then
                echo "Error: Passphrase cannot be empty." >&2
                exit 1
              fi
              printf "%s" "$entered_pass" > "$pass_file"
            fi

            echo "Enrolling devices with TPM2 (Target PCRs: $target_pcrs)..."
            for dev in "''${devices[@]}"; do
              echo "----------------------------------------------------------"
              echo "Processing $dev..."
              if [ ! -e "$dev" ]; then
                echo "Warning: Device $dev not found, skipping."
                continue
              fi

              if [ "$force_mode" = true ]; then
                echo "Force mode enabled: wiping existing TPM2 tokens and keyslots..."
                if meta=$(cryptsetup luksDump --dump-json-metadata "$dev" 2>/dev/null); then
                  token_ids=$(echo "$meta" | jq -r '.tokens | to_entries[]? | select(.value.type == "systemd-tpm2") | .key' 2>/dev/null || true)
                  for tid in $token_ids; do
                    ks=$(echo "$meta" | jq -r ".tokens[\"$tid\"].keyslots[0]" 2>/dev/null || true)
                    echo "Wiping TPM2 token $tid from $dev..."
                    cryptsetup token remove --token-id="$tid" "$dev" 2>/dev/null || true
                    if [ -n "$ks" ] && [ "$ks" != "null" ]; then
                      echo "Wiping keyslot $ks associated with token $tid..."
                      cryptsetup luksKillSlot -q --key-file="$pass_file" "$dev" "$ks" 2>/dev/null || true
                    fi
                  done
                fi
              fi

              systemd-cryptenroll \
                --unlock-key-file="$pass_file" \
                --tpm2-device=auto \
                --tpm2-pcrs="$target_pcrs" \
                --wipe-slot=tpm2 \
                "$dev"
            done
            echo "----------------------------------------------------------"
            echo "TPM enrollment process completed successfully."
    '';
  };

  tpmTools = pkgs.runCommand "tpm-tools" {} ''
    mkdir -p $out/bin
    ln -s ${tpmScript}/bin/tpm-reenroll $out/bin/tpm-reenroll
    ln -s ${tpmScript}/bin/tpm-reenroll $out/bin/tpm-enroll
  '';
in {
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
      default = "0+2+7+12";
      example = "0+2+7+12";
      description = ''
        PCR values to bind the TPM enrollment to.
        Default includes firmware (0), Option ROMs / PCIe configuration (2),
        Secure Boot policy (7), and kernel command line / configuration (12).
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.devices != [];
        message = "tpm.devices must be set when tpm.enable is true";
      }
      {
        assertion = cfg.passwordFile != null;
        message = "tpm.passwordFile must be set when tpm.enable is true";
      }
    ];

    environment.systemPackages = [tpmTools];

    systemd.services.tpm-enroll = {
      description = "Enroll LUKS devices in tpm2";
      wantedBy = ["multi-user.target"];
      after = ["tpm2.target" "agenix.service"];
      wants = ["tpm2.target" "agenix.service"];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${tpmScript}/bin/tpm-reenroll";
      };
    };
  };
}
