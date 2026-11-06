# Copyright (c) Joel Benway
# SPDX-License-Identifier: MIT
{
  config,
  lib,
  pkgs,
  inputs,
  ...
}: let
  superpowersSrc =
    inputs.superpowers or (pkgs.fetchFromGitHub {
      owner = "obra";
      repo = "superpowers";
      rev = "22f0b463e7a5e579904dd6211a520321035526f7";
      hash = "sha256-rP5YsyGuPd9YSW/Fj3aukrq1bLuV+nwwQMK4JaZQgkI=";
    });

  userConfigType = lib.types.submodule {
    options = {
      ide = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = config.antigravity.ide.enable;
          description = "Enable Antigravity IDE for this user";
        };
      };
      agy = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = config.antigravity.agy.enable;
          description = "Enable Antigravity CLI (agy) for this user";
        };
      };
      cpp = lib.mkEnableOption "Enables cpp tooling";
      flutter = lib.mkEnableOption "Enables Dart/Flutter tooling";
      nix = lib.mkEnableOption "Enables nix tooling";
      python = lib.mkEnableOption "Enables python tooling";
      shell = lib.mkEnableOption "Enables Shell tooling";
      ai = lib.mkEnableOption "Enables AI tooling";
      superpowers = lib.mkOption {
        type = lib.types.nullOr lib.types.bool;
        default = null;
        description = "Enables Superpowers agent skills (defaults to ai)";
      };
      servers = lib.mkOption {
        type = lib.types.attrs;
        default = {};
        description = "MCP servers for Antigravity";
      };
    }; # options
  }; # userConfigType
in {
  options.antigravity = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enables Antigravity (defaults both IDE and agy)";
    };
    ide = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = config.antigravity.enable;
        description = "Enables Antigravity IDE";
      };
    };
    agy = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = config.antigravity.enable;
        description = "Enables Antigravity CLI (agy)";
      };
    };
    superpowers = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Enables Superpowers agent skills";
      };
    };
    users = lib.mkOption {
      type = lib.types.attrsOf userConfigType;
      default = {};
      description = "User configuration";
    }; # users
  }; # options.antigravity

  config = {
    home-manager.users =
      lib.mapAttrs (
        user: userConfig: hm: let
          enableSuperpowers =
            if userConfig.superpowers != null
            then userConfig.superpowers
            else (userConfig.ai && config.antigravity.superpowers.enable);
        in {
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

          home = lib.mkIf (userConfig.ide.enable || userConfig.agy.enable) {
            file =
              (lib.optionalAttrs userConfig.ai {
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
              })
              // (lib.optionalAttrs enableSuperpowers {
                ".gemini/config/skills" = {
                  source = "${superpowersSrc}/skills";
                  recursive = true;
                };
              });

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
            antigravity-cli = lib.mkIf userConfig.agy.enable {
              enable = true;
              package = pkgs.antigravity-cli;
              enableMcpIntegration = userConfig.ai;
              mcpServers = lib.mkIf userConfig.ai userConfig.servers;
              skills = lib.mkIf enableSuperpowers "${superpowersSrc}/skills";
            };

            antigravity = lib.mkIf userConfig.ide.enable {
              enable = true;
              # Work around expired localhost TLS certificate (cert.pem notAfter Nov 3 2026)
              # bundled in antigravity-ide 2.5.5 for 127.0.0.1 Language Server HTTP/2 IPC.
              package = pkgs.antigravity-ide.overrideAttrs (old: {
                postPatch =
                  (old.postPatch or "")
                  + ''
                    if [ -f resources/app/out/main.js ]; then
                      substituteInPlace resources/app/out/main.js \
                        --replace-warn "nodeOptions:{ca:n}" "nodeOptions:{ca:n,rejectUnauthorized:!1}"
                    fi
                    if [ -f resources/app/extensions/antigravity/dist/extension.js ]; then
                      substituteInPlace resources/app/extensions/antigravity/dist/extension.js \
                        --replace-warn "nodeOptions:{ca:R}" "nodeOptions:{ca:R,rejectUnauthorized:!1}"
                    fi
                  '';
              });
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
        }
      )
      config.antigravity.users;
  }; # config
}
