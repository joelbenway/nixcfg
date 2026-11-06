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
      gnugrep
      gnused
      jq
      sbctl
      systemd
      util-linux
    ];
    text = ''
      devices=(${lib.escapeShellArgs cfg.devices})
      target_pcrs="${cfg.pcrs}"
      state_dir="/var/lib/tpm-enroll"
      state_file="''${state_dir}/pcr-state.json"
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
        --status                Show current keyslots, TPM tokens, and system PCR measurements
        --force                 Force re-enrollment even if target PCRs are already enrolled
        --check-reboot-safety   Verify TPM tokens and check for PCR drift before unattended reboot
        -h, --help              Show this help message
      EOF
      }

      # Returns compact JSON object mapping target PCR numbers to their live SHA256 digests
      get_live_pcrs_json() {
        local want
        want=$(jq -cn --arg p "$target_pcrs" '$p | split("+") | map(tonumber)')
        systemd-analyze pcrs --json=short 2>/dev/null | jq -c --argjson want "$want" '
          [ .[] | select(.nr as $n | $want | index($n)) | {key: (.nr | tostring), value: .sha256} ]
          | sort_by(.key | tonumber)
          | from_entries
        ' 2>/dev/null || echo "{}"
      }

      # Returns 0 if device has a systemd-tpm2 token matching target_pcrs indices, 1 otherwise
      device_has_target_token() {
        local dev="$1"
        local meta want
        meta=$(cryptsetup luksDump --dump-json-metadata "$dev" 2>/dev/null) || return 1
        want=$(jq -cn --arg p "$target_pcrs" '$p | split("+") | map(tonumber) | sort')
        echo "$meta" | jq -e --argjson want "$want" \
          '[.tokens[]? | select(.type == "systemd-tpm2") | (.["tpm2-pcrs"] | sort)] | any(. == $want)' >/dev/null 2>&1
      }

      # Returns 0 if recorded PCR digests in state_file match live TPM PCR digests
      live_pcrs_match_saved() {
        if [ ! -f "$state_file" ]; then
          return 1
        fi
        local live saved
        live=$(get_live_pcrs_json)
        if [ "$live" = "{}" ] || [ -z "$live" ]; then
          return 1
        fi
        saved=$(jq -c '.pcrs // {}' "$state_file" 2>/dev/null || echo "{}")
        [ "$live" = "$saved" ]
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
        systemd-analyze pcrs 2>/dev/null | grep -E '^ *(0|2|7|12)\b' || true
        if [ -f "$state_file" ]; then
          echo ""
          echo "Enrolled Baseline PCR State ($state_file):"
          jq . "$state_file" 2>/dev/null || true
        fi
        echo "=========================================================="
      }

      check_reboot_safety() {
        local reasons=()

        # 1. Check if live PCRs have drifted from the enrolled baseline or if any device lacks the target token.
        # If so, attempt an automatic re-enroll against current live PCRs first!
        local needs_reenroll=false
        if ! live_pcrs_match_saved; then
          needs_reenroll=true
        else
          for dev in "''${devices[@]}"; do
            if [ -e "$dev" ] && ! device_has_target_token "$dev"; then
              needs_reenroll=true
            fi
          done
        fi

        if [ "$needs_reenroll" = true ]; then
          echo "Live PCRs differ from saved baseline or token missing; attempting automatic re-enrollment against current live PCRs..."
          if "$0" --force >/dev/null 2>&1 && live_pcrs_match_saved; then
            echo "Successfully re-enrolled TPM2 tokens against current live PCRs."
          else
            reasons+=("Live TPM PCR digests ($target_pcrs) do not match enrolled baseline and automatic re-enrollment failed")
          fi
        fi

        # 2. Verify all configured devices exist and have the target TPM2 token enrolled
        for dev in "''${devices[@]}"; do
          if [ ! -e "$dev" ]; then
            reasons+=("LUKS device $dev is missing")
            continue
          fi
          if ! device_has_target_token "$dev"; then
            reasons+=("LUKS device $dev lacks a valid systemd-tpm2 token for PCRs $target_pcrs")
          fi
        done

        # 3. Check Secure Boot & Lanzaboote signature state (affects PCR 7)
        if ${lib.boolToString (config.boot.lanzaboote.enable or false)}; then
          if ! sbctl status --json 2>/dev/null | jq -e '.secure_boot == true' >/dev/null 2>&1; then
            reasons+=("Secure Boot is not currently active according to sbctl status")
          fi
          local verify_json
          if ! verify_json=$(sbctl verify --json 2>/dev/null) || \
             ! echo "$verify_json" | jq -e 'type == "array" and length > 0 and ([.[] | select(.is_signed == 0)] | length == 0)' >/dev/null 2>&1; then
            reasons+=("One or more EFI binaries in /boot failed sbctl signature verification (PCR 7/boot failure risk)")
          fi
        fi

        # 4. Check if kernel command line parameters (excluding NixOS store path) changed in a way that could alter external EFI options
        if [ -e /run/booted-system/kernel-params ] && [ -e /run/current-system/kernel-params ]; then
          local booted_params current_params
          booted_params=$(cat /run/booted-system/kernel-params)
          current_params=$(cat /run/current-system/kernel-params)
          if [ "$booted_params" != "$current_params" ]; then
            reasons+=("Kernel command-line parameters changed between booted-system ('$booted_params') and current-system ('$current_params')")
          fi
        fi

        # 5. Check if PCR 12 is non-zero (indicating systemd-stub or dynamic credentials extended PCR 12 during boot)
        # If PCR 12 is non-zero AND the initrd/systemd version in current-system changed, PCR 12 may change on next boot.
        local pcr12_val
        pcr12_val=$(get_live_pcrs_json | jq -r '.["12"] // ""')
        if [ -n "$pcr12_val" ] && ! [[ "$pcr12_val" =~ ^0+$ ]]; then
          if [ "$(readlink -f /run/booted-system/systemd)" != "$(readlink -f /run/current-system/systemd)" ] || \
             [ "$(readlink -f /run/booted-system/initrd)" != "$(readlink -f /run/current-system/initrd)" ]; then
            reasons+=("PCR 12 is actively extended ($pcr12_val) and initrd/systemd changed; next boot may alter PCR 12")
          fi
        fi

        if [ "''${#reasons[@]}" -gt 0 ]; then
          printf '%s\n' "''${reasons[@]}"
          exit 2
        fi

        echo "TPM reboot safety verified for PCRs $target_pcrs."
        exit 0
      }

      force_mode=false
      status_mode=false
      check_safety_mode=false

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
          --check-reboot-safety)
            check_safety_mode=true
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

      if [ "$check_safety_mode" = true ]; then
        check_reboot_safety
      fi

      # Determine whether any device needs enrollment or if live PCRs drifted from saved state
      needs_enroll=false
      if [ "$force_mode" = true ]; then
        needs_enroll=true
      elif ! live_pcrs_match_saved; then
        echo "Detected live TPM PCR drift (or missing baseline $state_file); forcing TPM token refresh..."
        needs_enroll=true
        force_mode=true
      else
        for dev in "''${devices[@]}"; do
          if [ -e "$dev" ] && ! device_has_target_token "$dev"; then
            needs_enroll=true
          fi
        done
      fi

      if [ "$needs_enroll" = false ]; then
        echo "All LUKS devices already enrolled with PCRs $target_pcrs and match live PCR digests."
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

        if [ "$force_mode" != true ] && device_has_target_token "$dev"; then
          echo "$dev already enrolled with PCRs $target_pcrs, skipping (use --force to re-enroll)."
          continue
        fi

        systemd-cryptenroll \
          --unlock-key-file="$pass_file" \
          --tpm2-device=auto \
          --tpm2-pcrs="$target_pcrs" \
          --wipe-slot=tpm2 \
          "$dev"
      done

      mkdir -p "$state_dir"
      chmod 0700 "$state_dir"
      live_pcrs=$(get_live_pcrs_json)
      jq -n \
        --arg target "$target_pcrs" \
        --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg sys "$(readlink -f /run/current-system 2>/dev/null || echo unknown)" \
        --argjson pcrs "$live_pcrs" \
        '{targetPcrs: $target, enrolledAt: $ts, system: $sys, pcrs: $pcrs}' > "$state_file"
      chmod 0600 "$state_file"

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

    impermanence.directories = lib.optionals (config.impermanence.enable or false) [
      {
        directory = "/var/lib/tpm-enroll";
        mode = "0700";
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
        ExecStart = "${tpmScript}/bin/tpm-reenroll";
      };
    };
  };
}
