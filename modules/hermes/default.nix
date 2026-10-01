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
    ];
    text = ''
      set -euo pipefail

      REPO_PATH="''${1:-${cfg.repoPath}}"
      HOST_NAME="''${2:-${cfg.hostName}}"
      LEAF_FILE="modules/hermes/agent-env.nix"

      echo "==> [Agentic GitOps] Initiating rebuild for host '#''${HOST_NAME}' in ' ''${REPO_PATH}'..."

      if [ ! -d "''${REPO_PATH}" ]; then
        echo "ERROR: Repository path ' ''${REPO_PATH}' does not exist!" >&2
        exit 1
      fi

      cd "''${REPO_PATH}"

      # Prevent git 'dubious ownership' issues across user boundaries
      export GIT_CONFIG_COUNT=1
      export GIT_CONFIG_KEY_0="safe.directory"
      export GIT_CONFIG_VALUE_0="''${REPO_PATH}"

      # Stage and commit leaf file changes if dirty
      if [ -f "''${LEAF_FILE}" ] && ! git diff --quiet "''${LEAF_FILE}"; then
        echo "==> [GitOps] Version-controlling changes to ''${LEAF_FILE}..."
        git add "''${LEAF_FILE}"
        git -c user.name="Hermes Agent" -c user.email="hermes-agent@local" commit -m "chore(hermes): auto-commit agent-env.nix dependency updates"
      fi

      # Step a: Validate flake syntax and purity
      echo "==> [1/4] Validating flake syntax and purity (nix flake check)..."
      nix flake check "''${REPO_PATH}" --no-build

      # Step b: Build generation in isolation
      echo "==> [2/4] Building system generation for #''${HOST_NAME}..."
      nixos-rebuild build --flake "''${REPO_PATH}#''${HOST_NAME}"

      # Step c: Switch system generations
      echo "==> [3/4] Activating new system generation (nixos-rebuild switch)..."
      nixos-rebuild switch --flake "''${REPO_PATH}#''${HOST_NAME}"

      # Step d: Canary health check
      echo "==> [4/4] Probing hermes-agent.service health..."
      HEALTHY=0
      for i in $(seq 1 15); do
        if systemctl is-active --quiet hermes-agent.service; then
          echo "==> Canary check passed: hermes-agent.service is active and healthy (probe $i/15)."
          HEALTHY=1
          break
        fi
        sleep 1
      done

      if [ "''${HEALTHY}" -ne 1 ]; then
        echo "ERROR: Canary check failed! hermes-agent.service is NOT active after 15 seconds." >&2
        echo "==> Triggering automated rollback (nixos-rebuild switch --rollback)..." >&2
        nixos-rebuild switch --rollback
        exit 1
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
    ];

    # Blast Radius: Only the leaf file is writable by the hermes user/group
    systemd.tmpfiles.rules = [
      "z ${cfg.repoPath}/modules/hermes/agent-env.nix 0664 hermes hermes - -"
    ];

    # Privilege Separation: Only allow rebuild-agent-env via sudo without password
    security.sudo.extraRules = [
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
    ];

    services.hermes-agent = {
      enable = true;
      container.enable = false; # Native mode (no container layers)

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
          threshold = 0.7;
          summary_model = "nvidia/nemotron-3.5-lightning-30b-a3b";
          protect_last_n = 5;
        };
        memory = {
          memory_enabled = true;
          user_profile_enabled = true;
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
              if [ ! -d /var/lib/signal-cli/data ] && [ -d /home/joel/.local/share/signal-cli/data ]; then
                echo "==> Migrating Signal credentials from /home/joel/.local/share/signal-cli to /var/lib/signal-cli..."
                cp -r /home/joel/.local/share/signal-cli/* /var/lib/signal-cli/
                chown -R hermes:hermes /var/lib/signal-cli
                chmod -R 0700 /var/lib/signal-cli
              fi
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

      # Directly inject extraPackages to service PATH
      path = agentEnv.extraPackages;

      serviceConfig = {
        # Allow sudo privilege escalation inside the service
        NoNewPrivileges = lib.mkForce false;

        # Allow hermes to modify the leaf module within the sandboxed namespace
        ReadWritePaths = [
          "${cfg.repoPath}/modules/hermes/agent-env.nix"
        ];
      };
    };
  }; # config
}
