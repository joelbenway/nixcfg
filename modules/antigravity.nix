# Copyright (c) Joel Benway
# SPDX-License-Identifier: MIT
{
  config,
  lib,
  pkgs,
  inputs,
  ...
}: let
  userConfigType = lib.types.submodule {
    options = {
      cpp = lib.mkEnableOption "Enables cpp tooling";
      flutter = lib.mkEnableOption "Enables Dart/Flutter tooling";
      nix = lib.mkEnableOption "Enables nix tooling";
      python = lib.mkEnableOption "Enables python tooling";
      shell = lib.mkEnableOption "Enables Shell tooling";
      ai = lib.mkEnableOption "Enables AI tooling";
      servers = lib.mkOption {
        type = lib.types.attrs;
        default = {};
        description = "MCP servers for Antigravity";
      };
    }; # options
  }; # userConfigType
in {
  options.antigravity = {
    enable = lib.mkEnableOption "Enables antigravity";
    users = lib.mkOption {
      type = lib.types.attrsOf userConfigType;
      default = {};
      description = "User configuration";
    }; # users
  }; # options.antigravity

  config = lib.mkIf config.antigravity.enable {
    home-manager.users =
      lib.mapAttrs (user: userConfig: hm: {
        disabledModules = ["programs/antigravity.nix"];
        imports = [
          (import "${inputs.home-manager}/modules/programs/vscode/mkVscodeModule.nix" {
            modulePath = ["programs" "antigravity"];
            name = "Antigravity IDE";
            packageName = "antigravity-ide";
            nameShort = "Antigravity IDE";
            dataFolderName = ".antigravity-ide";
            skipVersionCheck = true;
          })
        ];

        home = {
          file = lib.mkIf userConfig.ai {
            ".gemini/config/mcp_config.json".text = let
              allServers =
                (lib.optionalAttrs (hm.config.programs ? mcp && hm.config.programs.mcp.enable) hm.config.programs.mcp.servers)
                // userConfig.servers;

              cleanServer = srv: let
                isDisabled =
                  if (srv.disabled or false) == true
                  then true
                  else if (srv.enabled or null) == false
                  then true
                  else null;
                common = {
                  disabled = isDisabled;
                  disabledTools = srv.disabledTools or null;
                  alwaysAllow = srv.alwaysAllow or null;
                };
              in
                if (srv.command or null) != null
                then
                  lib.filterAttrs (_: v: v != null && v != [] && v != {}) ({
                      inherit (srv) command;
                      args = srv.args or null;
                      env = srv.env or null;
                      cwd = srv.cwd or null;
                    }
                    // common)
                else if (srv.serverUrl or srv.url or null) != null
                then
                  lib.filterAttrs (_: v: v != null && v != [] && v != {}) ({
                      serverUrl = srv.serverUrl or srv.url;
                      headers = srv.headers or null;
                    }
                    // common)
                else {};
            in
              builtins.toJSON {
                mcpServers = lib.mapAttrs (_: cleanServer) allServers;
              };
          };

          packages = with pkgs;
            lib.optionals userConfig.cpp [
              clang-tools
            ]
            ++ lib.optionals userConfig.nix [
              alejandra
              nixd
            ]
            ++ lib.optionals userConfig.shell [
              bash-language-server
              shellcheck
              shfmt
            ]
            ++ lib.optionals userConfig.ai [
              # mcp-language-server
            ]; # packages
        }; # home

        programs = {
          antigravity = {
            enable = true;
            package = pkgs.antigravity-ide;
            mutableExtensionsDir = false;
            profiles = {
              default = {
                enableMcpIntegration = userConfig.ai;
                extensions = with pkgs.vscode-extensions;
                  [
                    mkhl.direnv
                  ]
                  ++ lib.optionals userConfig.cpp [
                    llvm-vs-code-extensions.vscode-clangd
                    ms-vscode.cmake-tools
                    vadimcn.vscode-lldb
                  ]
                  ++ lib.optionals userConfig.flutter [
                    dart-code.dart-code
                    dart-code.flutter
                  ]
                  ++ lib.optionals userConfig.nix [
                    jnoortheen.nix-ide
                  ]
                  ++ lib.optionals userConfig.python [
                    ms-python.python
                  ]
                  ++ lib.optionals userConfig.shell [
                    mads-hartmann.bash-ide-vscode
                  ]; # extensions
                userSettings = {
                  "files.watcherExclude" = {
                    "**/.direnv" = true;
                    "**/.direnv/**" = true;
                    "**/.git/objects/**" = true;
                    "**/.git/subtree-cache/**" = true;
                    "**/result" = true;
                    "**/result/**" = true;
                  };
                  diffEditor = {
                    ignoreTrimWhitespace = false;
                  };
                  editor = {
                    tabSize = 2;
                    tabCompletion = "on";
                  };
                  clangd = lib.mkIf userConfig.cpp {
                    checkUpdates = false;
                  }; # clangd
                  nix = lib.mkIf userConfig.nix {
                    enableLanguageServer = true;
                    serverPath = "nixd";
                    serverSettings = {
                      nixd = {
                        formatting = {
                          command = ["alejandra"];
                        }; # formatting
                        options = {
                          nixos = lib.mkIf (config.networking.hostName != null) {
                            "expr" = let
                              workspaceFolder = "\${workspaceFolder}";
                            in "(builtins.getFlake \"${workspaceFolder}\").nixosConfigurations.${config.networking.hostName}.options";
                          }; # nixos
                        }; # options
                      }; # "nixd"
                    }; # serverSettings
                    formatterPath = "alejandra";
                  }; # nix
                }; # userSettings
                userTasks = {
                }; # userTasks
              }; # default
            }; # profiles
          }; # antigravity
        }; # programs
      })
      config.antigravity.users;
  }; # config
}
