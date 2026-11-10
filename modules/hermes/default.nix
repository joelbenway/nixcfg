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

  # Privilege-separated rebuild script
  rebuildScript = pkgs.writeShellApplication {
    name = "rebuild-agent-env";
    runtimeInputs = with pkgs; [
      nix
      nixos-rebuild
      git
      systemd
      coreutils
      findutils
    ];
    text = ''
      set -euo pipefail

      REPO_PATH="''${1:-${cfg.repoPath}}"
      HOST_NAME="''${2:-${cfg.hostName}}"
      REPO_LEAF="''${REPO_PATH}/modules/hermes/agent-env.nix"
      RUNTIME_LEAF="${cfg.runtimeLeafPath}"
      HERMES_USER="hermes"
      HERMES_HOME="/var/lib/hermes"
      PROFILE_PATH="''${HERMES_HOME}/.nix-profile"

      echo "==> [Agentic GitOps] Initiating environment rebuild for Hermes Agent..."

      # Bootstrap runtime leaf from baseline if missing
      if [ ! -f "''${RUNTIME_LEAF}" ]; then
        if [ -f "''${REPO_LEAF}" ]; then
          cp "''${REPO_LEAF}" "''${RUNTIME_LEAF}"
        else
          cp "${./agent-env.nix}" "''${RUNTIME_LEAF}"
        fi
        chown "''${HERMES_USER}:''${HERMES_USER}" "''${RUNTIME_LEAF}" 2>/dev/null || true
        chmod 0664 "''${RUNTIME_LEAF}" 2>/dev/null || true
      fi

      # If the agent edited REPO_LEAF more recently than RUNTIME_LEAF, copy REPO_LEAF -> RUNTIME_LEAF;
      # otherwise copy RUNTIME_LEAF -> REPO_LEAF so both stay identical.
      if [ -f "''${REPO_LEAF}" ] && [ "''${REPO_LEAF}" -nt "''${RUNTIME_LEAF}" ]; then
        cp "''${REPO_LEAF}" "''${RUNTIME_LEAF}"
        chown "''${HERMES_USER}:''${HERMES_USER}" "''${RUNTIME_LEAF}" 2>/dev/null || true
        chmod 0664 "''${RUNTIME_LEAF}" 2>/dev/null || true
      elif [ -d "''${REPO_PATH}/modules/hermes" ]; then
        cp "''${RUNTIME_LEAF}" "''${REPO_LEAF}"
        chown "''${HERMES_USER}:''${HERMES_USER}" "''${REPO_LEAF}" 2>/dev/null || true
        chmod 0664 "''${REPO_LEAF}" 2>/dev/null || true
      fi

      LEAF_FILE="''${RUNTIME_LEAF}"

      if ! nix-instantiate --parse "''${LEAF_FILE}" >/dev/null; then
        echo "ERROR: Syntax error in ' ''${LEAF_FILE}'!" >&2
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
        export GIT_CONFIG_VALUE_0="*"
        git config --global --add safe.directory "''${REPO_PATH}" 2>/dev/null || true
        git config --global --add safe.directory '*' 2>/dev/null || true

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
          echo "==> [GitOps] Leaf config ' ''${LEAF_FILE}' updated (skipping git commit: repository owned by host user)."
        fi
      fi

      # 2. Build declarative package environment from leaf config
      echo "==> [1/3] Building declarative package environment from leaf config..."
      ENV_OUT=$(nix-build --no-out-link -I nixpkgs=${pkgs.path} -E "let pkgs = import <nixpkgs> {}; agentEnv = import ''${LEAF_FILE} { inherit pkgs; }; in pkgs.buildEnv { name = \"hermes-agent-env\"; paths = (agentEnv.extraPackages or []); }")

      echo "==> Built environment derivation: ''${ENV_OUT}"

      # 3. Atomically activate new profile generation
      echo "==> [2/3] Activating new environment generation in ''${PROFILE_PATH}..."
      mkdir -p "''${HERMES_HOME}/.local/state/nix/profiles"
      nix-env -p "''${PROFILE_PATH}" --set "''${ENV_OUT}"

      if [ "$(id -u)" -eq 0 ]; then
        chown -h -R "''${HERMES_USER}:''${HERMES_USER}" "''${HERMES_HOME}/.local" "''${HERMES_HOME}/.nix-profile" "''${PROFILE_PATH}"* 2>/dev/null || true
      fi

      if [ "''${1:-}" = "--system" ] || [ "''${2:-}" = "--system" ]; then
        echo "==> Full system switch requested (--system)..."
        nixos-rebuild switch --flake "''${REPO_PATH}#''${HOST_NAME}"
      fi

      # 4. Probing environment health
      echo "==> [3/3] Probing active environment health..."
      if [ -d "''${PROFILE_PATH}/bin" ]; then
        PKG_COUNT=$(find "''${PROFILE_PATH}/bin" -maxdepth 1 -type l | wc -l)
        echo "==> Health check passed: ''${PKG_COUNT} binaries available at ''${PROFILE_PATH}/bin."
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
      pkgs.signal-cli
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
            {
              command = "/run/current-system/sw/bin/systemctl restart hermes-agent";
              options = ["NOPASSWD"];
            }
            {
              command = "/run/current-system/sw/bin/systemctl restart hermes-agent.service";
              options = ["NOPASSWD"];
            }
            {
              command = "${pkgs.systemd}/bin/systemctl restart hermes-agent";
              options = ["NOPASSWD"];
            }
            {
              command = "${pkgs.systemd}/bin/systemctl restart hermes-agent.service";
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
        Defaults:hermes !authenticate
        Defaults:hermes timestamp_timeout=0
      '';
    };

    # System-wide git safe.directory trust to avoid libgit2 ownership rejections across users
    programs.git = {
      enable = true;
      config = {
        safe = {
          directory = [
            "*"
          ];
        };
      };
    };

    services.hermes-agent = {
      enable = true;
      container.enable = false; # Native mode (no container layers)
      package = let
        pmPackages =
          (pkgs.callPackage "${inputs.hermes-agent}/nix/pm-packages.nix" {})
          // {
            node = pkgs.nodejs_22;
          };
      in
        inputs.hermes-agent.packages.${pkgs.system}.default.override {inherit pmPackages;};

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

      # Directly inject extraPackages and runtime tools to service PATH
      path =
        agentEnv.extraPackages
        ++ (with pkgs; [
          nix
          git
          coreutils
          bashInteractive
        ]);

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
