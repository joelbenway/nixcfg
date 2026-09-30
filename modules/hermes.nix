{
  config,
  inputs,
  lib,
  pkgs,
  ...
}: let
  cfg = config.hermes;
in {
  options = {
    hermes = with lib; {
      enable = mkEnableOption "Hermes Agent";
      environmentFiles = mkOption {
        type = types.listOf types.str;
        default = [];
        description = "Environment files for hermes (e.g., agenix secrets)";
        example = literalExpression ''[ "/run/secrets/secrets.env" ]'';
      };
    }; # hermes
  }; # options

  imports = [
    inputs.hermes-agent.nixosModules.default
    (lib.custom.relativeToRoot "modules/llm.nix")
  ];

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.environmentFiles != [];
        message = "hermes.environmentFiles must be set (at least one env file with all required secrets)";
      }
    ];

    services = {
      hermes-agent = {
        enable = true;
        settings = {
          model = {
            provider = "deepseek";
            default = "deepseek-v4-pro";
            base_url = "";
            api_key = "";
          }; # model
          # fallback_providers = [
          #   {
          #     provider = "custom";
          #     base_url = "http://localhost:${config.llm.llamaPort}/v1";
          #     model = "gemma-4-e2b-it";
          #     api_key = "none";
          #   }
          # ];
          toolsets = ["all"];
          max_turns = 100;
          compression = {
            enabled = true;
            threshold = 0.7;
            summary_model = "deepseek-v4-flash";
            protect_last_n = 5;
          };
          memory = {
            memory_enabled = true;
            user_profile_enabled = true;
          }; # memory
          display = {
            compact = false;
            personality = "kawaii";
          }; # display
          agent = {
            max_turns = 60;
            verbose = true;
          }; # agent
        }; # settings
        environmentFiles = cfg.environmentFiles;
        documents = {
          # "USER.md" = ./documents/USER.md;
        }; # documents
        addToSystemPackages = true;
        extraArgs = [];
        extraPackages = with pkgs; [
          jq
          ripgrep
          curl
        ];
        extraDependencyGroups = ["messaging"];
        restart = "always";
        restartSec = 5;
      }; # hermes-agent
    }; # services
  }; # config
}
