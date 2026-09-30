{
  config,
  lib,
  ...
}: let
  userConfigType = lib.types.submodule {
    options = {
      enable = lib.mkEnableOption "Enable mcp servers for this user";
      servers = lib.mkOption {
        type = lib.types.attrs;
        default = {};
        description = "MCP server config (JSON-serializable)";
      }; # servers
    }; # options
  }; # userConfigType
in {
  options = {
    mcp = {
      users = lib.mkOption {
        type = lib.types.attrsOf userConfigType;
        default = {};
        description = "Per user configuration";
      }; # users
    }; # mcp
  }; # options

  config = {
    home-manager.users = lib.mapAttrs (user: cfg:
      lib.mkIf cfg.enable {
        programs = {
          mcp = {
            enable = true;
            servers = cfg.servers;
          }; # mcp
        }; # programs
      })
    config.mcp.users;
  }; # config
}
