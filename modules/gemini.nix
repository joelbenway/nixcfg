{
  config,
  lib,
  pkgs,
  ...
}: let
  userConfigType = lib.types.submodule {
    options = {
      enable = lib.mkEnableOption "Enable gemini-cli for this user";

      useOAuth = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Use OAuth authentication instead of API keys.
          When false, loadkeys will be automatically enabled to load API keys.
        '';
      }; # useOAuth
    }; # options
  }; # userConfigType
in {
  options.gemini = {
    users = lib.mkOption {
      type = lib.types.attrsOf userConfigType;
      default = {};
      description = "Per user configuration";
    }; # users
  }; # options.gemini

  config = {
    home-manager.users =
      lib.mapAttrs (
        user: cfg:
          lib.mkIf cfg.enable {
            programs = {
              gemini-cli = {
                enable = cfg.enable;
                package = pkgs.gemini-cli;
                enableMcpIntegration = true;
                settings = {
                  security = {
                    auth = {
                      selectedType =
                        if cfg.useOAuth
                        then "oauth-personal"
                        else "gemini-api-key"; # GEMINI_API_KEY environment variable
                    }; # auth
                  }; # security
                  general = {
                    previewFeatures = true;
                    disableAutoUpdate = true;
                  }; # general
                  ide = {
                    hasSeenNudge = true;
                    enabled = true;
                  }; # ide
                  tools = {
                    autoAccept = true;
                  }; # tools
                  ui = {
                    theme = "Default";
                  }; # ui
                }; # settings
              }; # gemini-cli
            }; # programs
          }
      )
      config.gemini.users;
  }; # config
}
