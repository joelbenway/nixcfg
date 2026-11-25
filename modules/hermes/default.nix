# Copyright (c) Joel Benway
# SPDX-License-Identifier: MIT
{
  config,
  inputs,
  lib,
  pkgs,
  ...
}: let
  cfg = config.hermes;
  agentEnv = import ./agent-env.nix {inherit pkgs;};

  # Script to merge leaf module extraSettings into Hermes's runtime config.yaml
  syncConfig = pkgs.writeScriptBin "sync-hermes-config" ''
    #!${pkgs.python3.withPackages (ps: [ps.ruamel-yaml])}/bin/python3
    import json
    import os
    from pathlib import Path
    import sys
    import tempfile
    from ruamel.yaml import YAML

    if len(sys.argv) < 3:
        print("Usage: sync-hermes-config <config_path> <extra_json>", file=sys.stderr)
        sys.exit(1)

    config_path = Path(sys.argv[1])
    extra_json = sys.argv[2]

    try:
        extra = json.loads(extra_json)
    except Exception as e:
        print(f"ERROR: Failed to parse extraSettings JSON: {e}", file=sys.stderr)
        sys.exit(1)

    if not isinstance(extra, dict):
        print(f"WARNING: extraSettings is not a dictionary (type: {type(extra)}), skipping merge.", file=sys.stderr)
        sys.exit(0)

    if not extra:
        print("==> No extraSettings to merge.")
        sys.exit(0)

    yaml = YAML(typ="safe", pure=True)
    yaml.version = (1, 1)
    yaml.default_flow_style = False
    yaml.sort_base_mapping_type_on_output = False

    existing = {}
    if config_path.exists():
        try:
            with open(config_path, "r", encoding="utf-8") as f:
                existing = yaml.load(f) or {}
        except Exception as e:
            print(f"WARNING: Failed to read existing {config_path}: {e}", file=sys.stderr)

    def deep_merge(base, override):
        result = dict(base)
        for k, v in override.items():
            if k in result and isinstance(result[k], dict) and isinstance(v, dict):
                result[k] = deep_merge(result[k], v)
            else:
                result[k] = v
        return result

    merged = deep_merge(existing, extra)

    if merged == existing:
        print("==> Hermes configuration is already up to date.")
        sys.exit(0)

    config_path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(prefix=".config.", dir=str(config_path.parent))
    tmp_path = Path(tmp_name)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            yaml.dump(merged, f)
            f.flush()

            if config_path.exists():
                st = config_path.stat()
                try:
                    os.fchmod(f.fileno(), st.st_mode)
                except Exception:
                    pass
                try:
                    os.fchown(f.fileno(), st.st_uid, st.st_gid)
                except Exception:
                    pass
            else:
                try:
                    os.fchmod(f.fileno(), 0o660)
                except Exception:
                    pass
                if os.geteuid() == 0:
                    import pwd, grp
                    try:
                        uid = pwd.getpwnam("hermes").pw_uid
                        gid = grp.getgrnam("hermes").gr_gid
                        os.fchown(f.fileno(), uid, gid)
                    except Exception:
                        pass

        tmp_path.replace(config_path)
    except BaseException:
        try:
            tmp_path.unlink(missing_ok=True)
        except OSError:
            pass
        raise
    print(f"==> Hermes configuration updated successfully at {config_path}")
    sys.exit(42)
  '';

  # Privilege-separated rebuild script
  rebuildScript = pkgs.writeShellApplication {
    name = "rebuild-agent-env";
    runtimeInputs = with pkgs; [
      syncConfig
      nix
      nixos-rebuild
      git
      systemd
      coreutils
      findutils
      gnugrep
      util-linux
    ];
    text = ''
      set -euo pipefail

      REPO_PATH="${cfg.repoPath}"
      HOST_NAME="${cfg.hostName}"
      FULL_SYSTEM=0
      RESTART_REQUESTED=0
      REPO_PATH_SET=0
      HOST_NAME_SET=0

      CALLER_USER="''${SUDO_USER:-$(id -un)}"
      for arg in "$@"; do
        case "$arg" in
          --system)
            if [ "$CALLER_USER" = "hermes" ]; then
              echo "ERROR: --system is not permitted for the hermes user." >&2
              exit 1
            fi
            FULL_SYSTEM=1
            ;;
          --restart)
            RESTART_REQUESTED=1
            ;;
          -*)
            echo "Unknown flag: $arg" >&2
            exit 1
            ;;
          *)
            if [ "$CALLER_USER" = "hermes" ]; then
              echo "ERROR: Custom repo/host arguments are not permitted for the hermes user." >&2
              exit 1
            fi
            if [ "$REPO_PATH_SET" -eq 0 ]; then
              REPO_PATH="$arg"
              REPO_PATH_SET=1
            elif [ "$HOST_NAME_SET" -eq 0 ]; then
              HOST_NAME="$arg"
              HOST_NAME_SET=1
            fi
            ;;
        esac
      done

      REPO_LEAF="''${REPO_PATH}/modules/hermes/agent-env.nix"
      RUNTIME_LEAF="${cfg.runtimeLeafPath}"
      HERMES_USER="hermes"
      HERMES_HOME="/var/lib/hermes"
      PROFILE_PATH="''${HERMES_HOME}/.nix-profile"

      echo "==> [Agentic GitOps] Initiating environment rebuild for Hermes Agent..."

      run_as_hermes() {
        if [ "$(id -u)" -eq 0 ]; then
          runuser -u "''${HERMES_USER}" -- "$@"
        else
          "$@"
        fi
      }

      # Reject symlinks and perform all leaf file operations strictly as unprivileged hermes
      if [ -L "''${RUNTIME_LEAF}" ] || [ -L "''${REPO_LEAF}" ]; then
        echo "ERROR: Symlink detected at agent-env leaf path; refusing to proceed." >&2
        exit 1
      fi

      # Bootstrap runtime leaf from baseline if missing (runs as hermes so root never writes agent-writable paths)
      if [ ! -f "''${RUNTIME_LEAF}" ]; then
        if [ -f "''${REPO_LEAF}" ]; then
          run_as_hermes cp --remove-destination "''${REPO_LEAF}" "''${RUNTIME_LEAF}"
        else
          run_as_hermes cp --remove-destination "${./agent-env.nix}" "''${RUNTIME_LEAF}"
        fi
        run_as_hermes chmod 0664 "''${RUNTIME_LEAF}" 2>/dev/null || true
      fi

      # If the agent edited REPO_LEAF more recently than RUNTIME_LEAF, copy REPO_LEAF -> RUNTIME_LEAF;
      # otherwise copy RUNTIME_LEAF -> REPO_LEAF so both stay identical (all writes run as hermes).
      if [ -f "''${REPO_LEAF}" ] && [ "''${REPO_LEAF}" -nt "''${RUNTIME_LEAF}" ]; then
        run_as_hermes cp --remove-destination "''${REPO_LEAF}" "''${RUNTIME_LEAF}"
        run_as_hermes chmod 0664 "''${RUNTIME_LEAF}" 2>/dev/null || true
      elif [ -d "''${REPO_PATH}/modules/hermes" ]; then
        run_as_hermes cp --remove-destination "''${RUNTIME_LEAF}" "''${REPO_LEAF}" 2>/dev/null || true
        run_as_hermes chmod 0664 "''${REPO_LEAF}" 2>/dev/null || true
      fi

      LEAF_FILE="''${RUNTIME_LEAF}"

      # Evaluate agent-controlled Nix expressions strictly as the unprivileged hermes user
      if ! run_as_hermes nix-instantiate --parse "''${LEAF_FILE}" >/dev/null; then
        echo "ERROR: Syntax error in '''''${LEAF_FILE}'!" >&2
        exit 1
      fi

      # 1. Handle GitOps version control if repository exists
      if [ -d "''${REPO_PATH}/.git" ]; then
        if [ "$(id -u)" -eq 0 ]; then
          REPO_UID=$(stat -c '%u:%g' "''${REPO_PATH}")
          chown -R "''${REPO_UID}" "''${REPO_PATH}/.git" 2>/dev/null || true
        fi

        export GIT_CONFIG_COUNT=1
        export GIT_CONFIG_KEY_0="safe.directory"
        export GIT_CONFIG_VALUE_0="''${REPO_PATH}"

        if [ -w "''${REPO_PATH}/.git" ]; then
          (
            cd "''${REPO_PATH}"
            if ! git diff --quiet "''${REPO_LEAF}" 2>/dev/null; then
              echo "==> [GitOps] Version-controlling changes to ''${REPO_LEAF}..."
              AGENT_BRANCH="hermes/agent-env"
              CURRENT_BRANCH=$(git branch --show-current 2>/dev/null || echo "")
              if [ "$CURRENT_BRANCH" != "$AGENT_BRANCH" ]; then
                git checkout -B "$AGENT_BRANCH" 2>/dev/null || true
              fi
              git add "''${REPO_LEAF}"
              git -c user.name="Hermes Agent" -c user.email="hermes-agent@local" commit -m "chore(hermes): auto-commit agent-env.nix dependency updates" || true
              if [ "$(id -u)" -eq 0 ]; then
                chown -R "''${REPO_UID}" "''${REPO_PATH}/.git" 2>/dev/null || true
              fi
            fi
          )
        else
          echo "==> [GitOps] Leaf config '''''${LEAF_FILE}' updated (skipping git commit: repository owned by host user)."
        fi
      fi

      # 2. Build declarative package environment from leaf config (as unprivileged hermes user)
      echo "==> [1/4] Building declarative package environment from leaf config..."
      ENV_OUT=$(run_as_hermes nix-build --no-out-link -I nixpkgs=${pkgs.path} -E "let pkgs = import <nixpkgs> {}; agentEnv = import ''${LEAF_FILE} { inherit pkgs; }; in pkgs.buildEnv { name = \"hermes-agent-env\"; paths = (agentEnv.extraPackages or []); }")

      echo "==> Built environment derivation: ''${ENV_OUT}"

      # 3. Atomically activate new profile generation (as unprivileged hermes user)
      echo "==> [2/4] Activating new environment generation in ''${PROFILE_PATH}..."
      run_as_hermes mkdir -p "''${HERMES_HOME}/.local/state/nix/profiles"
      run_as_hermes nix-env -p "''${PROFILE_PATH}" --set "''${ENV_OUT}"

      if [ "$FULL_SYSTEM" -eq 1 ]; then
        echo "==> Full system switch requested (--system)..."
        nixos-rebuild switch --flake "''${REPO_PATH}#''${HOST_NAME}"
      fi

      # 4. Sync declarative runtime settings (extraSettings) into config.yaml (strictly as unprivileged hermes user)
      echo "==> [3/4] Syncing declarative settings into config.yaml..."
      CONFIG_CHANGED=0
      CONFIG_FILE="''${HERMES_HOME}/.hermes/config.yaml"
      EXTRA_JSON=$(run_as_hermes nix-instantiate --eval --strict --json -I nixpkgs=${pkgs.path} -E "let pkgs = import <nixpkgs> {}; agentEnv = import ''${LEAF_FILE} { inherit pkgs; }; in (agentEnv.extraSettings or {})" 2>/dev/null || echo "{}")

      SYNC_STATUS=0
      run_as_hermes sync-hermes-config "''${CONFIG_FILE}" "''${EXTRA_JSON}" || SYNC_STATUS=$?

      if [ "$SYNC_STATUS" -eq 42 ]; then
        CONFIG_CHANGED=1
      elif [ "$SYNC_STATUS" -ne 0 ]; then
        echo "WARNING: Failed to merge extraSettings into config.yaml (exit code: $SYNC_STATUS)" >&2
      fi

      # 5. Probing environment health
      echo "==> [4/4] Probing active environment health..."
      if [ -d "''${PROFILE_PATH}/bin" ]; then
        PKG_COUNT=$(find "''${PROFILE_PATH}/bin" -maxdepth 1 -type l | wc -l)
        echo "==> Health check passed: ''${PKG_COUNT} binaries available at ''${PROFILE_PATH}/bin."
      fi

      if [ "$CONFIG_CHANGED" -eq 1 ] || [ "$RESTART_REQUESTED" -eq 1 ]; then
        echo "==> Model/runtime configuration changed (or --restart requested)."
        if [ "$(id -u)" -eq 0 ]; then
          echo "==> Scheduling detached background service restart in 2 seconds..."
          systemd-run --on-active=2s systemctl restart hermes-agent
          echo "==> Service restart scheduled. Active conversation turn will complete cleanly."
        else
          echo "ERROR: Restart requires root privileges. Run 'sudo rebuild-agent-env --restart'." >&2
          exit 1
        fi
      fi

      echo "==> [Agentic GitOps] Environment successfully updated and verified active!"
    '';
  };
in {
  options = {
    hermes = with lib; {
      enable = mkEnableOption "Hermes Agent";
      environmentFiles = mkOption {
        type = types.listOf types.str;
        default = [];
        description = "Environment files for hermes (e.g. agenix secrets containing OPENROUTER_API_KEY).";
        example = literalExpression ''[ config.age.secrets.hermes-env.path ]'';
      };
      repoPath = mkOption {
        type = types.str;
        default = "/home/joel/Projects/nixcfg";
        description = "Absolute path to the NixOS configuration repository.";
      };
      runtimeLeafPath = mkOption {
        type = types.str;
        default = "/var/lib/hermes/agent-env.nix";
        description = "Persistent host-local path to Hermes's mutable agent-env.nix leaf.";
      };
      hostName = mkOption {
        type = types.str;
        default = config.networking.hostName;
        description = "Target host name in the flake nixosConfigurations.";
      };
    }; # hermes
  }; # options

  imports = [
    inputs.hermes-agent.nixosModules.default
  ];

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.environmentFiles != [];
        message = "hermes.environmentFiles must be set (at least one env file with required API secrets)";
      }
    ];

    environment.systemPackages = [
      rebuildScript
      syncConfig
      pkgs.qrencode
      (pkgs.writeShellScriptBin "hermes-chat" ''
        exec sudo -u hermes hermes chat "$@"
      '')
      (pkgs.writeShellScriptBin "hermes-cli" ''
        exec sudo -u hermes hermes "$@"
      '')
      (pkgs.writeShellScriptBin "signal-cli" ''
        if [[ "$*" == *"--config"* ]]; then
          exec sudo -u hermes ${pkgs.signal-cli}/bin/signal-cli "$@"
        else
          exec sudo -u hermes ${pkgs.signal-cli}/bin/signal-cli --config /var/lib/signal-cli "$@"
        fi
      '')
      (pkgs.writeShellScriptBin "signal-link" ''
        NAME="''${1:-Hermes-Zita}"
        echo "==> Generating Signal device link for ''${NAME}..."
        echo "==> Open Signal on your phone -> Settings -> Linked Devices -> Add Device (+)"
        sudo -u hermes ${pkgs.signal-cli}/bin/signal-cli --config /var/lib/signal-cli link -n "''${NAME}" | while read -r line; do
          echo "$line"
          if [[ "$line" =~ sgnl://linkdevice\?.* ]]; then
            URI="''${BASH_REMATCH[0]}"
            echo ""
            echo "Scan this QR code in Signal:"
            ${pkgs.qrencode}/bin/qrencode -t ansiutf8 "$URI" || true
            echo ""
            echo "Raw link: $URI"
          fi
        done
        echo "==> Device linked! Restarting signal-cli service..."
        sudo systemctl restart signal-cli.service
      '')
    ];

    # Blast Radius: Only the leaf file is writable by the hermes user/group,
    # and ~/.hermes must not have group-writable permissions (mode 0700)
    systemd.tmpfiles.rules = [
      "d /var/lib/hermes 0750 hermes hermes - -"
      "d /var/lib/hermes/.hermes 0700 hermes hermes - -"
      "C ${cfg.runtimeLeafPath} 0664 hermes hermes - ${./agent-env.nix}"
      "z ${cfg.runtimeLeafPath} 0664 hermes hermes - -"
      "z ${cfg.repoPath}/modules/hermes 2775 joel hermes - -"
      "z ${cfg.repoPath}/modules/hermes/agent-env.nix 0664 hermes hermes - -"
    ];

    # Privilege Separation: Only allow rebuild-agent-env via sudo without password,
    # and allow wheel users to interact with the hermes gateway user without password
    security.sudo = {
      extraRules = [
        {
          users = ["hermes"];
          commands = [
            {
              command = "${rebuildScript}/bin/rebuild-agent-env";
              options = ["NOPASSWD"];
            }
            {
              command = "/run/current-system/sw/bin/rebuild-agent-env";
              options = ["NOPASSWD"];
            }
          ];
        }
        {
          groups = ["wheel"];
          runAs = "hermes";
          commands = [
            {
              command = "ALL";
              options = ["NOPASSWD"];
            }
          ];
        }
      ];
      extraConfig = ''
        Defaults:hermes timestamp_timeout=0
      '';
    };

    services.hermes-agent = {
      enable = true;
      container.enable = false; # Native mode (no container layers)
      package = let
        # Upstream hermes-agent unconditionally patches patchelf assuming 0.19.2
        # (NixOS/patchelf#674), which fails to apply on nixpkgs's patchelf 0.15.2.
        # On < 0.19.0, stock patchelf is unaffected, so make overrideAttrs a no-op.
        patchelfForPm =
          if lib.versionOlder pkgs.patchelf.version "0.19.0"
          then pkgs.patchelf // {overrideAttrs = _: pkgs.patchelf;}
          else pkgs.patchelf;
        pmPackages =
          lib.filterAttrs (_: lib.isDerivation) (
            pkgs.callPackage "${inputs.hermes-agent}/nix/pm-packages.nix" {
              patchelf = patchelfForPm;
            }
          )
          // {
            node = pkgs.nodejs_26;
          };
      in
        inputs.hermes-agent.packages.${pkgs.stdenv.hostPlatform.system}.default.override {inherit pmPackages;};

      # Inject dependencies from leaf module
      extraPackages = agentEnv.extraPackages;

      # Merge base settings with leaf module overrides
      settings = lib.recursiveUpdate {
        model = {
          provider = "openrouter";
          default = "nvidia/nemotron-3-ultra-550b-a55b:free";
          base_url = "";
          api_key = "";
        };

        auxiliary = {
          review = {
            provider = "nvidia";
            model = "z-ai/glm-5.3-flash";
          };
          side_question = {
            provider = "nvidia";
            model = "z-ai/glm-5.3-flash";
          };
          vision = {
            provider = "google";
            model = "gemma-4-31b-it";
          };
          compression = {
            provider = "nvidia";
            model = "nvidia/nemotron-3.5-lightning-30b-a3b";
          };
        };

        fallback_providers = [
          {
            provider = "nvidia";
            model = "z-ai/glm-5.3-flash";
          }
          {
            provider = "nvidia";
            model = "nvidia/nemotron-3.5-lightning-30b-a3b";
          }
          {
            provider = "google";
            model = "gemma-4-31b-it";
          }
          {
            provider = "deepseek";
            model = "deepseek-flash";
          }
          {
            provider = "custom";
            base_url = "http://localhost:8080/v1";
            model = "gemma-4-e4b-it";
            api_key = "none";
          }
        ];
        toolsets = ["all"];
        max_turns = 100;
        compression = {
          enabled = true;
          threshold = 0.25;
          summary_model = "nvidia/nemotron-3.5-lightning-30b-a3b";
          protect_last_n = 5;
        };
        memory = {
          memory_enabled = true;
          user_profile_enabled = true;
          provider = "builtin";
        };
        display = {
          compact = false;
          personality = "default";
        };
        agent = {
          max_turns = 60;
          verbose = true;
        };
      } (agentEnv.extraSettings or {});

      # MCP servers from leaf module
      mcpServers = agentEnv.mcpServers or {};

      environmentFiles = cfg.environmentFiles;

      # Install SOUL.md system prompt guidance for the agent
      hermesHomeFiles = {
        "SOUL.md" = ./SOUL.md;
      };

      addToSystemPackages = true;
      extraDependencyGroups = ["messaging"];
      restart = "always";
      restartSec = 5;
    };

    # Signal CLI Daemon for Hermes
    systemd.services.signal-cli = {
      description = "Signal CLI Daemon for Hermes Agent";
      after = ["network.target" "agenix.service"];
      wants = ["network.target" "agenix.service"];
      wantedBy = ["multi-user.target"];
      serviceConfig = {
        User = "hermes";
        Group = "hermes";
        StateDirectory = "signal-cli";
        ExecStartPre = [
          ("+"
            + (pkgs.writeShellScript "signal-cli-credentials-setup" ''
              mkdir -p /var/lib/signal-cli
              chown -R hermes:hermes /var/lib/signal-cli
              chmod -R 0700 /var/lib/signal-cli
            ''))
        ];
        EnvironmentFile = cfg.environmentFiles;
        ExecStart = "${pkgs.signal-cli}/bin/signal-cli --config /var/lib/signal-cli daemon --http 127.0.0.1:8085";
        Restart = "always";
        RestartSec = 5;
      };
    };

    # Systemd service sandboxing adjustments & direct PATH injection
    systemd.services.hermes-agent = {
      after = ["signal-cli.service"];
      wants = ["signal-cli.service"];

      environment.PATH = lib.mkForce (lib.concatStringsSep ":" [
        "/var/lib/hermes/.nix-profile/bin"
        "/var/lib/hermes/.local/bin"
        "/run/wrappers/bin"
        "/run/current-system/sw/bin"
        (lib.makeBinPath (
          agentEnv.extraPackages
          ++ (with pkgs; [
            nix
            git
            coreutils
            bashInteractive
            systemd
          ])
        ))
      ]);

      serviceConfig = {
        # Allow sudo privilege escalation inside the service
        NoNewPrivileges = lib.mkForce false;

        # Allow hermes to modify the leaf module and its home state within the sandboxed namespace
        ReadWritePaths = [
          "-${cfg.repoPath}/modules/hermes/agent-env.nix"
          "/var/lib/hermes"
          "-/run/sudo"
        ];
      };
    };
  }; # config
}
